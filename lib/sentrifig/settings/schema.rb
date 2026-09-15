# frozen_string_literal: true

require_relative "definition"

module Sentrifig
  module Settings
    # Every setting an operator can change at runtime, per scope.
    #
    # The bar for inclusion is strict: the SDK concerned must read the option
    # *after* initialisation, so that changing it here actually changes
    # behaviour. Options captured when the client is built are deliberately
    # absent -- a field that silently does nothing is worse than no field.
    #
    # Verified against sentry-ruby 7.0.0 and @sentry/core 9.47.1:
    #
    #   in  -- Configuration#sample_allowed?, #sending_allowed? and
    #          #excluded_exception? are called per event on the live
    #          configuration object; Client#getOptions() in the browser returns
    #          the live _options, and sampleRate is read inside _processEvent.
    #   out -- dsn (the transport is built from it in Client#initialize),
    #          breadcrumbs_logger and enabled_patches (applied once at
    #          Sentry.init), debug (binds the SDK logger at init).
    module Schema
      BACKEND = [
        Definition.new(
          key: :sample_rate,
          type: :float,
          range: 0.0..1.0,
          default: 1.0,
          env: "SENTRY_SAMPLE_RATE",
          description: "Fraction of errors sent. 0.5 sends half of them."
        ),
        Definition.new(
          key: :traces_sample_rate,
          type: :float,
          range: 0.0..1.0,
          default: 1.0,
          env: "SENTRY_TRACING_SAMPLE_RATE",
          description: "Fraction of performance transactions sent.",
          note: "Only has an effect where tracing is enabled (SENTRY_TRACING_ENABLE)."
        ),
        Definition.new(
          key: :send_default_pii,
          type: :boolean,
          default: false,
          env: "SENTRY_PII_ENABLE",
          description: "Send personal information (IP addresses, cookies, user context) with events."
        ),
        Definition.new(
          key: :max_breadcrumbs,
          type: :integer,
          range: 0..100,
          default: 50,
          description: "Breadcrumbs kept per event. Sentry's own maximum is 100.",
          note: "Applies to scopes created after the change, so in a web app from the next request."
        ),
        Definition.new(
          key: :include_local_variables,
          type: :boolean,
          default: true,
          description: "Include local variables in stack frames.",
          note: "Locals can carry credentials and tokens. The Authorization filter still applies, but it only covers headers."
        ),
        Definition.new(
          key: :excluded_exceptions,
          type: :string_list,
          default: -> { SentrySetup::EXCLUDED_EXCEPTIONS.dup },
          description: "Exception class names never reported. Comma-separated."
        ),
        Definition.new(
          key: :enabled_environments,
          type: :string_list,
          default: -> { SentrySetup::ENABLED_ENVIRONMENTS.dup },
          description: "Environments allowed to send at all. Comma-separated.",
          note: "Removing this environment from the list stops everything, the same as the switch."
        ),
        Definition.new(
          key: :release,
          type: :string,
          default: nil,
          env: "APP_RELEASE_TAG",
          description: "Release tag attached to events. Blank lets Sentry detect it."
        )
      ].freeze

      # The browser SDK's own options, served to clients by the state endpoint
      # and applied by sentrifig-browser to the running client.
      FRONTEND = [
        Definition.new(
          key: :sample_rate,
          type: :float,
          range: 0.0..1.0,
          default: 1.0,
          description: "Fraction of browser errors sent."
        ),
        Definition.new(
          key: :traces_sample_rate,
          type: :float,
          range: 0.0..1.0,
          default: 0.1,
          description: "Fraction of browser performance transactions sent."
        ),
        Definition.new(
          key: :replays_session_sample_rate,
          type: :float,
          range: 0.0..1.0,
          default: 0.01,
          description: "Fraction of sessions recorded as a replay.",
          note: "Sampled when a session starts, so this applies to new sessions, not open tabs."
        ),
        Definition.new(
          key: :replays_on_error_sample_rate,
          type: :float,
          range: 0.0..1.0,
          default: 1.0,
          description: "Fraction of errored sessions recorded as a replay."
        ),
        Definition.new(
          key: :send_default_pii,
          type: :boolean,
          default: false,
          description: "Send personal information with browser events."
        )
      ].freeze

      ALL = { Scope::BACKEND => BACKEND, Scope::FRONTEND => FRONTEND }.freeze

      module_function

      # @return [Array<Definition>]
      def for_scope(scope)
        ALL.fetch(Scope.coerce(scope))
      end

      # @return [Definition, nil]
      def find(scope, key)
        for_scope(scope).find { |definition| definition.key == key.to_sym }
      end

      def keys(scope)
        for_scope(scope).map(&:key)
      end

      # Defaults for every setting in the scope, with no stored values applied.
      def defaults(scope)
        for_scope(scope).to_h { |definition| [definition.key, definition.default_value] }
      end

      # Validates a hash of raw input against the scope.
      #
      # @return [Array(Hash, Hash)] cast values keyed by symbol, and errors
      #   keyed by symbol. Unknown keys are an error rather than silently
      #   dropped, so a typo in a rake task or an API call is not mistaken for
      #   a successful write.
      def cast(scope, input)
        values = {}
        errors = {}

        input.each do |key, raw|
          definition = find(scope, key)
          next errors[key.to_sym] = "is not a setting for the #{scope} scope" if definition.nil?

          value, error = definition.cast(raw)
          error ? errors[definition.key] = error : values[definition.key] = value
        end

        [values, errors]
      end
    end
  end
end
