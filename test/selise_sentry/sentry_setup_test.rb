# frozen_string_literal: true

require "test_helper"

module SeliseSentry
  class SentrySetupTest < ActiveSupport::TestCase
    ALL_VARS = %w[SENTRY_ENABLED SENTRY_DSN RUNTIME_ENVIRONMENT APP_RELEASE_TAG SENTRY_DEBUG_ENABLE SENTRY_PII_ENABLE
                  SENTRY_SAMPLE_RATE SENTRY_TRACING_ENABLE SENTRY_TRACING_SAMPLE_RATE SENTRY_HEALTH_CHECK_ENDPOINTS].freeze

    def defaults(env = {})
      with_env(ALL_VARS.to_h { |v| [v, nil] }.merge(env)) do
        SentrySetup.apply_defaults(Sentry::Configuration.new)
      end
    end

    test "sends nothing unless SENTRY_ENABLED is true" do
      assert_nil defaults("SENTRY_DSN" => "http://k:s@sentry.localdomain/1").dsn
      assert_nil defaults("SENTRY_ENABLED" => "false", "SENTRY_DSN" => "http://k:s@sentry.localdomain/1").dsn
      assert_equal "sentry.localdomain", defaults("SENTRY_ENABLED" => "true", "SENTRY_DSN" => "http://k:s@sentry.localdomain/1").dsn.host
    end

    test "boolean flags treat the string 'false' as false" do
      config = defaults("SENTRY_PII_ENABLE" => "false", "SENTRY_DEBUG_ENABLE" => "false")
      assert_equal false, config.send_default_pii
      assert_equal false, config.debug

      config = defaults("SENTRY_PII_ENABLE" => "TRUE", "SENTRY_DEBUG_ENABLE" => "1")
      assert_equal true, config.send_default_pii
      assert_equal true, config.debug
    end

    test "safe defaults when nothing is set" do
      config = defaults
      assert_equal false, config.send_default_pii
      assert_equal false, config.debug
      assert_equal 1.0, config.sample_rate
      assert_equal true, config.include_local_variables
      assert_equal 50, config.max_breadcrumbs
      assert_equal 5, config.context_lines
      assert_equal %w[production staging], config.enabled_environments
      assert_includes config.excluded_exceptions, "ActionController::RoutingError"
      assert_includes config.excluded_exceptions, "ActiveRecord::RecordNotFound"
      assert_equal false, config.inspect_exception_causes_for_exclusion
      assert_equal true, config.enable_backpressure_handling
      assert_equal false, config.propagate_traces
      assert_equal [], config.trace_propagation_targets
      assert_same SentrySetup::STRIP_AUTHORIZATION, config.before_send
      assert_equal false, config.rails.structured_logging.enabled
      assert_includes config.enabled_patches, :http
      assert_includes config.enabled_patches, :puma
      assert_nil config.traces_sample_rate, "tracing stays off unless SENTRY_TRACING_ENABLE is true"
      assert_nil config.traces_sampler
    end

    test "sample rate, release and environment come from the environment" do
      config = defaults("SENTRY_SAMPLE_RATE" => "0.25", "APP_RELEASE_TAG" => "v1.2.3", "RUNTIME_ENVIRONMENT" => "staging")
      assert_equal 0.25, config.sample_rate
      assert_equal "v1.2.3", config.release
      assert_equal "staging", config.environment
    end

    test "unparseable numbers fall back to the default" do
      assert_equal 1.0, defaults("SENTRY_SAMPLE_RATE" => "lots").sample_rate
    end

    test "tracing is enabled with the default sampler only when asked" do
      config = defaults("SENTRY_TRACING_ENABLE" => "true", "SENTRY_TRACING_SAMPLE_RATE" => "0.5")
      assert_equal 0.5, config.traces_sample_rate
      assert_same SentrySetup::DEFAULT_TRACES_SAMPLER, config.traces_sampler
    end

    test "default sampler honours parent decisions, health checks and path families" do
      sampler = SentrySetup::DEFAULT_TRACES_SAMPLER
      with_env("SENTRY_HEALTH_CHECK_ENDPOINTS" => "/healthier/ping,/healthier/live", "SENTRY_TRACING_SAMPLE_RATE" => nil) do
        assert_equal true, sampler.call(parent_sampled: true, transaction_context: {}, env: {})
        assert_equal 0.0, sampler.call(parent_sampled: nil, transaction_context: { op: "queue.sidekiq", name: "Job" }, env: nil)
        assert_equal 0.1, sampler.call(parent_sampled: nil, transaction_context: { op: "http.server", name: "/healthier/ping" },
                                       env: { "PATH_INFO" => "/healthier/ping" })
        assert_equal 0.2, sampler.call(parent_sampled: nil, transaction_context: { op: "http.server", name: "/healthier/other" },
                                       env: { "PATH_INFO" => "/healthier/other" })
        assert_equal 0.3, sampler.call(parent_sampled: nil, transaction_context: { op: "http.server", name: "/api/v1/x" }, env: { "PATH_INFO" => "/api/v1/x" })
        assert_equal 0.4, sampler.call(parent_sampled: nil, transaction_context: { op: "http.server", name: "/graphql" }, env: { "PATH_INFO" => "/graphql" })
        assert_equal 0.5, sampler.call(parent_sampled: nil, transaction_context: { op: "http.server", name: "/orders" }, env: { "PATH_INFO" => "/orders" })
      end
      with_env("SENTRY_TRACING_SAMPLE_RATE" => "0.5", "SENTRY_HEALTH_CHECK_ENDPOINTS" => nil) do
        assert_in_delta 0.25, sampler.call(parent_sampled: nil, transaction_context: { op: "http.server", name: "/orders" }, env: { "PATH_INFO" => "/orders" })
      end
    end

    test "STRIP_AUTHORIZATION removes Authorization from the request and breadcrumbs, any casing" do
      # Sentry itself drops Authorization unless PII is on; the filter must hold even then.
      Sentry.configuration.send_default_pii = true
      event = Sentry.get_current_client.event_from_message("x")
      event.rack_env = {
        "REQUEST_METHOD" => "GET", "PATH_INFO" => "/x", "rack.input" => StringIO.new,
        "HTTP_AUTHORIZATION" => "Bearer leaked", "HTTP_X_REQUEST_ID" => "abc"
      }
      assert event.request.headers.key?("Authorization"), "precondition: Sentry captured the header"
      event.request.headers["authorization"] = "lower"
      crumb = Sentry::Breadcrumb.new(category: "net.http", data: { "Authorization" => "Bearer crumb", "url" => "https://amp/x",
                                                                   headers: { "Authorization" => "nested" }, "headers" => { "authorization" => "nested2" } })
      event.breadcrumbs = Sentry::BreadcrumbBuffer.new
      event.breadcrumbs.record(crumb)

      assert_same event, SentrySetup::STRIP_AUTHORIZATION.call(event, {})
      assert_not event.request.headers.keys.any? { |k| k.to_s.casecmp?("authorization") }
      assert_equal "abc", event.request.headers["X-Request-Id"]
      assert_equal({ "url" => "https://amp/x", headers: {}, "headers" => {} }, crumb.data)
    end

    test "STRIP_AUTHORIZATION tolerates events without request or breadcrumbs" do
      event = Sentry::TransactionEvent.new(configuration: Sentry.configuration, transaction: Sentry.start_transaction(name: "t", op: "x"))
      assert_same event, SentrySetup::STRIP_AUTHORIZATION.call(event, nil)
    end

    test "init! skips and warns when the application already initialised Sentry" do
      logger, log = capturing_logger
      configure_selise_sentry(logger: logger)
      assert_equal false, SentrySetup.init!
      assert_includes log.string, "already initialised"
    end

    test "configuration helpers" do
      config = Configuration.new
      assert_raises(ConfigurationError) { config.initialize_sentry = nil }
      assert_raises(ConfigurationError) { config.sentry }
      config.initialize_sentry = false
      config.sentry { |s| s.debug = true }
      assert_equal false, config.initialize_sentry
      assert_equal 1, config.sentry_overrides.size
    end
  end
end
