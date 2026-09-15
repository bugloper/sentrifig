# frozen_string_literal: true

require "logger"
require "sentry-ruby"
require "sentry-rails" if defined?(::Rails::Railtie)

require_relative "sentrifig/version"
require_relative "sentrifig/errors"
require_relative "sentrifig/configuration"
require_relative "sentrifig/scope"
require_relative "sentrifig/settings/schema"
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

    # Resolved settings for a scope: stored override, else the environment
    # variable, else the schema default.
    #
    # @return [Hash{Symbol=>Object}]
    def settings(scope = Scope::BACKEND)
      runtime(scope).settings
    end

    # Validates and stores setting overrides, then applies the backend ones to
    # the running Sentry SDK immediately. A key mapped to nil is reset to its
    # default.
    #
    # @param input [Hash] raw values; strings from a form are cast by the schema
    # @raise [ValidationError] with every failing key named
    # @raise [PersistenceError]
    # @return [Hash{Symbol=>Object}] the resolved settings afterwards
    def update_settings!(scope = Scope::BACKEND, input = {}, by: nil)
      scope = Scope.coerce(scope)
      resets, assignments = input.partition { |_key, value| value.nil? }

      values, errors = Settings::Schema.cast(scope, assignments.to_h)
      unless errors.empty?
        raise ValidationError, errors.map { |key, message| "#{key} #{message}" }.join("; ")
      end

      resets.each { |key, _| values[key.to_sym] = nil }

      result = runtime(scope).update_settings!(values, by: by)
      apply_to_sentry! if scope == Scope::BACKEND
      result
    end

    # Resets one setting to its default.
    def reset_setting!(scope = Scope::BACKEND, key = nil, by: nil)
      scope = Scope.coerce(scope)
      raise ValidationError, "#{key} is not a setting for the #{scope} scope" unless Settings::Schema.find(scope, key)

      update_settings!(scope, { key.to_sym => nil }, by: by)
    end

    # Pushes stored setting *overrides* onto the live Sentry configuration.
    #
    # Only overrides, never defaults: by the time this runs, SentrySetup and the
    # application's own `config.sentry { }` blocks have already produced the
    # baseline. Re-asserting schema defaults here would silently undo an app's
    # deliberate configuration -- which it did, until the gate test caught it.
    #
    # Only options sentry-ruby reads per event are in the schema, so this takes
    # effect for the next event rather than needing a restart.
    #
    # @return [Boolean] false when Sentry is not initialised
    def apply_to_sentry!
      return false unless ::Sentry.initialized?

      baseline # capture what the app configured, before we change any of it

      sentry = ::Sentry.configuration
      overrides = runtime(Scope::BACKEND).overridden_keys
      resolved = settings(Scope::BACKEND)

      Settings::Schema.for_scope(Scope::BACKEND).each do |definition|
        key = definition.key
        value = overrides.include?(key) ? resolved[key] : baseline[key]
        next if key == :release && value.nil? # leave Sentry's own detection alone

        sentry.public_send(:"#{key}=", value) if sentry.respond_to?(:"#{key}=")
      end
      true
    rescue StandardError => e
      # Never let a settings change break the SDK it is configuring.
      logger.error("[sentrifig] could not apply settings to Sentry: #{e.class}: #{e.message}")
      false
    end

    # What the Sentry configuration held before sentrifig touched it: the
    # environment variables plus the application's own `config.sentry { }`
    # blocks. This, not the schema's literal default, is what "default" means on
    # the dashboard and what resetting a setting restores.
    #
    # Captured once, the first time it is needed after Sentry.init.
    # @return [Hash{Symbol=>Object}]
    def baseline
      return @baseline if @baseline
      return {} unless ::Sentry.initialized?

      sentry = ::Sentry.configuration
      captured = Settings::Schema.for_scope(Scope::BACKEND).to_h do |definition|
        value = sentry.respond_to?(definition.key) ? sentry.public_send(definition.key) : definition.default_value
        [definition.key, dup_if_possible(value)]
      end

      MUTEX.synchronize { @baseline ||= captured.freeze }
    end

    # @api private
    def dup_if_possible(value)
      value.dup
    rescue StandardError
      value
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
        @baseline = nil
      end
    end
  end
end
