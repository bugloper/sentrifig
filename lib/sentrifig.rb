# frozen_string_literal: true

require "logger"
require "sentry-ruby"
require "sentry-rails" if defined?(::Rails::Railtie)

require_relative "sentrifig/version"
require_relative "sentrifig/errors"
require_relative "sentrifig/configuration"
require_relative "sentrifig/scope"
require_relative "sentrifig/store"
require_relative "sentrifig/runtime"
require_relative "sentrifig/gate"
require_relative "sentrifig/sentry_setup"
require_relative "sentrifig/engine" if defined?(::Rails::Railtie)

# Runtime on/off switch for Sentry.
#
#   Sentrifig.enabled?   # => true  (the backend switch)
#   Sentrifig.disable!   # persists, takes effect immediately in this process
#   Sentrifig.enable!
#   Sentrifig.status     # => #<struct enabled=true, environment="production", ...>
#
# State is stored per (environment, scope). "backend" gates this process's
# Sentry SDK; "frontend" is served to browser clients over HTTP and gates
# theirs. See Sentrifig::Scope.
#
#   Sentrifig.enabled_for?(Sentrifig::Scope::FRONTEND)
#   Sentrifig.disable!(scope: "frontend", by: "alice")
module Sentrifig
  MUTEX = Mutex.new
  private_constant :MUTEX

  class << self
    # @yieldparam config [Configuration]
    def configure
      yield configuration if block_given?
      configuration.validate!
      MUTEX.synchronize do
        @runtimes = nil
        @backend_runtime = nil
      end
      configuration
    end

    def configuration
      @configuration || MUTEX.synchronize { @configuration ||= Configuration.new }
    end

    # Hot path. Cheap: an in-memory read plus a clock comparison.
    #
    # Backend only, by design: this is what Gate::PROCESSOR calls on every
    # Sentry event. @backend_runtime is a direct reference rather than a lookup
    # in #runtimes so the scope split costs the hot path nothing.
    def enabled?
      (@backend_runtime || runtime(Scope::BACKEND)).enabled?
    end

    # Any scope. Not a hot path: the frontend switch is read once per HTTP
    # request to the state endpoint, never per Sentry event.
    def enabled_for?(scope)
      runtime(scope).enabled?
    end

    # @param by [String, nil] who made the change, recorded for audit purposes
    # @param scope [String] which switch to move
    # @raise [PersistenceError] when the state could not be saved
    def enable!(by: nil, scope: Scope::BACKEND)
      runtime(scope).update!(true, by: by)
    end

    # @param by [String, nil] who made the change, recorded for audit purposes
    # @param scope [String] which switch to move
    # @raise [PersistenceError] when the state could not be saved
    def disable!(by: nil, scope: Scope::BACKEND)
      runtime(scope).update!(false, by: by)
    end

    # @return [Runtime::Status] switch state plus whether the Sentry SDK itself can send
    #
    # sdk_ready/sdk_problems describe this process's Ruby SDK and are merged in
    # for every scope. They are meaningful on the dashboard, which renders them
    # once; the state endpoint deliberately does not serialise them.
    def status(scope = Scope::BACKEND)
      status = runtime(scope).status
      status.sdk_ready, status.sdk_problems = sdk_state
      status
    end

    # @return [Array<Runtime::Status>] one status per scope, in Scope::ALL order
    def statuses
      Scope::ALL.map { |scope| status(scope) }
    end

    def current_environment
      configuration.environment
    end

    # Re-reads the state from the database now instead of waiting for the TTL.
    # With no argument, refreshes every scope.
    def refresh!(scope = nil)
      scopes = scope ? [Scope.coerce(scope)] : Scope::ALL
      scopes.each { |s| runtime(s).refresh! }
      enabled_for?(scope || Scope::BACKEND)
    end

    # Registers the Sentry gate. Called automatically by the Rails engine.
    def install!
      Gate.install!
    end

    def logger
      configuration.logger
    end

    # @api private — [ready, problems] for the SDK independent of the switch.
    def sdk_state
      return [false, ["Sentry SDK is not initialised"]] unless ::Sentry.initialized?

      configuration = ::Sentry.configuration
      return [true, []] if configuration.sending_allowed?

      problems = configuration.respond_to?(:errors) ? Array(configuration.errors).map(&:to_s) : []
      problems = ["DSN missing or environment not enabled"] if problems.empty?
      [false, problems]
    rescue StandardError => e
      [false, ["#{e.class}: #{e.message}"]]
    end

    # @api private — kept callable with no argument: the shipped test_helper
    #   (and therefore consumers) call Sentrifig.runtime.
    def runtime(scope = Scope::BACKEND)
      runtimes.fetch(Scope.coerce(scope))
    end

    # @api private
    def runtimes
      return @runtimes if @runtimes

      config = configuration # resolved outside the lock: it takes the same mutex
      MUTEX.synchronize do
        @runtimes ||= begin
          built = Scope::ALL.to_h { |s| [s, Runtime.new(configuration: config, scope: s)] }.freeze
          @backend_runtime = built.fetch(Scope::BACKEND)
          built
        end
      end
    end

    # @api private — forgets configuration and cached state. For tests.
    def reset!
      MUTEX.synchronize do
        @configuration = nil
        @runtimes = nil
        @backend_runtime = nil
      end
    end
  end
end
