# frozen_string_literal: true

module Sentrifig
  # Selise's default Sentry.init, driven by the environment variables SELISE
  # deployments already define, so an application needs no Sentry initializer.
  #
  # Applied by the engine after the application's config/initializers have run,
  # so anything registered with
  #
  #   Sentrifig.configure do |config|
  #     config.sentry { |sentry| sentry.excluded_exceptions += ["MyApp::Ignored"] }
  #   end
  #
  # lands on top of the defaults. Set config.initialize_sentry = false to keep
  # an application's own Sentry.init instead.
  #
  # Environment variables (all optional):
  #
  #   SENTRY_ENABLED                true/false  send only when true (default false)
  #   SENTRY_DSN                    the DSN, used only when SENTRY_ENABLED is true
  #   RUNTIME_ENVIRONMENT           Sentry environment (default: Sentry's own detection, usually RAILS_ENV)
  #   APP_RELEASE_TAG               release (default: Sentry's own detection)
  #   SENTRY_DEBUG_ENABLE           true/false  SDK debug logging (default false)
  #   SENTRY_PII_ENABLE             true/false  send_default_pii (default false)
  #   SENTRY_SAMPLE_RATE            error sample rate, 0..1 (default 1)
  #   SENTRY_TRACING_ENABLE         true/false  performance tracing (default false)
  #   SENTRY_TRACING_SAMPLE_RATE    trace sample rate, 0..1 (default 1), used with the default sampler
  #   SENTRY_HEALTH_CHECK_ENDPOINTS comma-separated paths sampled at 10% by the default sampler
  #
  # Booleans accept true/1/yes/on (case-insensitive); anything else is false.
  module SentrySetup
    TRUE_VALUES = %w[true 1 yes on].freeze
    ENABLED_ENVIRONMENTS = %w[production staging].freeze
    EXCLUDED_EXCEPTIONS = %w[ActionController::RoutingError ActiveRecord::RecordNotFound].freeze
    HEALTH_CHECK_SAMPLE_RATE = 0.1

    # Removes the Authorization header (any casing) from the event's request
    # and from HTTP-client breadcrumb data before sending. Applications that
    # forward user tokens to other services would otherwise leak them through
    # include_local_variables and the Faraday/Net::HTTP breadcrumb patches.
    STRIP_AUTHORIZATION = lambda do |event, _hint|
      strip = lambda do |headers|
        next unless headers.is_a?(Hash)

        headers.reject! { |key, _value| key.to_s.downcase == "authorization" }
      end

      strip.call(event.request.headers) if event.respond_to?(:request) && event.request.respond_to?(:headers)

      event.breadcrumbs&.buffer&.each do |breadcrumb|
        next unless breadcrumb.respond_to?(:data) && breadcrumb.data.is_a?(Hash)

        strip.call(breadcrumb.data)
        strip.call(breadcrumb.data[:headers])
        strip.call(breadcrumb.data["headers"])
      end

      event
    end

    # Samples inbound HTTP transactions by path family; health checks at 10%.
    # Continues the caller's sampling decision on distributed traces.
    DEFAULT_TRACES_SAMPLER = lambda do |sampling_context|
      next sampling_context[:parent_sampled] unless sampling_context[:parent_sampled].nil?

      transaction_context = sampling_context[:transaction_context] || {}
      rack_env = sampling_context[:env]
      next 0.0 unless transaction_context[:op] == "http.server" || (rack_env && !rack_env.empty?)

      path = rack_env ? rack_env["PATH_INFO"].to_s : transaction_context[:name].to_s
      health_check_paths = ENV.fetch("SENTRY_HEALTH_CHECK_ENDPOINTS", "").split(",").map(&:strip).reject(&:empty?)
      next HEALTH_CHECK_SAMPLE_RATE if health_check_paths.any? { |prefix| path.start_with?(prefix) }

      base = SentrySetup.env_float("SENTRY_TRACING_SAMPLE_RATE", 1.0)
      weight =
        case transaction_context[:name].to_s
        when /healthier/ then 0.2
        when /oauth/, /api/ then 0.3
        when /graphql/ then 0.4
        else 0.5
        end
      (base * weight).clamp(0.0, 1.0)
    end

    class << self
      # @return [Boolean] true when Sentry was initialised by this call
      def init!(configuration = Sentrifig.configuration)
        if ::Sentry.initialized?
          Sentrifig.logger.warn(
            "[sentrifig] Sentry was already initialised by the application; skipping the default Sentry.init. " \
            "Remove the application's Sentry.init or set config.initialize_sentry = false."
          )
          return false
        end

        ::Sentry.init do |sentry|
          apply_defaults(sentry)
          configuration.sentry_overrides.each { |override| override.call(sentry) }
        end
        true
      end

      # Mutates a Sentry::Configuration in place with the Selise defaults.
      def apply_defaults(sentry)
        sentry.dsn = env_flag("SENTRY_ENABLED", false) ? ENV.fetch("SENTRY_DSN", nil) : nil
        sentry.debug = env_flag("SENTRY_DEBUG_ENABLE", false)
        sentry.release = ENV["APP_RELEASE_TAG"] unless ENV["APP_RELEASE_TAG"].to_s.strip.empty?
        sentry.sample_rate = env_float("SENTRY_SAMPLE_RATE", 1.0)
        sentry.send_default_pii = env_flag("SENTRY_PII_ENABLE", false)
        sentry.include_local_variables = true
        sentry.max_breadcrumbs = 50
        sentry.breadcrumbs_logger = %i[active_support_logger sentry_logger http_logger]
        sentry.context_lines = 5
        sentry.environment = ENV["RUNTIME_ENVIRONMENT"] unless ENV["RUNTIME_ENVIRONMENT"].to_s.strip.empty?
        sentry.enabled_environments = ENABLED_ENVIRONMENTS.dup
        sentry.excluded_exceptions += EXCLUDED_EXCEPTIONS
        sentry.inspect_exception_causes_for_exclusion = false
        sentry.enabled_patches = (sentry.enabled_patches + optional_patches).uniq
        sentry.enable_backpressure_handling = true
        sentry.propagate_traces = false
        sentry.trace_propagation_targets = []
        sentry.trace_ignore_status_codes = [] if sentry.respond_to?(:trace_ignore_status_codes=)
        sentry.before_send = STRIP_AUTHORIZATION

        if env_flag("SENTRY_TRACING_ENABLE", false)
          sentry.traces_sample_rate = env_float("SENTRY_TRACING_SAMPLE_RATE", 1.0)
          sentry.traces_sampler = DEFAULT_TRACES_SAMPLER
        end

        # Sentry Logs ship every ActiveRecord/controller event as a log line; logs belong to the
        # application's own logging pipeline. sentry-rails 7.0 turned this on by default.
        sentry.rails.structured_logging.enabled = false if sentry.respond_to?(:rails) && sentry.rails.respond_to?(:structured_logging)

        sentry
      end

      def env_flag(name, default)
        value = ENV.fetch(name, nil).to_s.strip
        return default if value.empty?

        TRUE_VALUES.include?(value.downcase)
      end

      def env_float(name, default)
        value = ENV.fetch(name, nil).to_s.strip
        return default if value.empty?

        Float(value)
      rescue ArgumentError
        default
      end

      private

      def optional_patches
        patches = %i[http puma]
        patches << :graphql if defined?(::GraphQL)
        patches << :faraday if defined?(::Faraday)
        patches
      end
    end
  end
end
