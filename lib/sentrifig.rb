# frozen_string_literal: true

require "logger"
require "sentry-ruby"
require "sentry-rails" if defined?(::Rails::Railtie)

require_relative "sentrifig/version"
require_relative "sentrifig/errors"
require_relative "sentrifig/configuration"
require_relative "sentrifig/store"
require_relative "sentrifig/runtime"
require_relative "sentrifig/gate"
require_relative "sentrifig/sentry_setup"
require_relative "sentrifig/engine" if defined?(::Rails::Railtie)

# Runtime on/off switch for Sentry.
#
#   Sentrifig.enabled?   # => true
#   Sentrifig.disable!   # persists, takes effect immediately in this process
#   Sentrifig.enable!
#   Sentrifig.status     # => #<struct enabled=true, environment="production", ...>
module Sentrifig
  MUTEX = Mutex.new
  private_constant :MUTEX

  class << self
    # @yieldparam config [Configuration]
    def configure
      yield configuration if block_given?
      configuration.validate!
      MUTEX.synchronize { @runtime = nil }
      configuration
    end

    def configuration
      @configuration || MUTEX.synchronize { @configuration ||= Configuration.new }
    end

    # Hot path. Cheap: an in-memory read plus a clock comparison.
    def enabled?
      runtime.enabled?
    end

    # @param by [String, nil] who made the change, recorded for audit purposes
    # @raise [PersistenceError] when the state could not be saved
    def enable!(by: nil)
      runtime.update!(true, by: by)
    end

    # @param by [String, nil] who made the change, recorded for audit purposes
    # @raise [PersistenceError] when the state could not be saved
    def disable!(by: nil)
      runtime.update!(false, by: by)
    end

    # @return [Runtime::Status] switch state plus whether the Sentry SDK itself can send
    def status
      status = runtime.status
      status.sdk_ready, status.sdk_problems = sdk_state
      status
    end

    def current_environment
      configuration.environment
    end

    # Re-reads the state from the database now instead of waiting for the TTL.
    def refresh!
      runtime.refresh!
      enabled?
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

    # @api private
    def runtime
      return @runtime if @runtime

      config = configuration # resolved outside the lock: it takes the same mutex
      MUTEX.synchronize { @runtime ||= Runtime.new(configuration: config) }
    end

    # @api private — forgets configuration and cached state. For tests.
    def reset!
      MUTEX.synchronize do
        @configuration = nil
        @runtime = nil
      end
    end
  end
end
