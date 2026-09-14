# frozen_string_literal: true

require "test_helper"

module Sentrifig
  class ConfigurationTest < ActiveSupport::TestCase
    test "defaults" do
      config = Configuration.new

      assert_nil config.username
      assert_nil config.password
      assert_equal true, config.enabled_by_default
      assert_equal Configuration::DEFAULT_CACHE_TTL, config.cache_ttl
      assert_equal "test", config.environment
      assert_same Rails.logger, config.logger
      assert_not config.credentials_configured?
      assert config.validate!
    end

    test "credentials default to the SENTRIFIG_USERNAME/PASSWORD environment variables" do
      with_env("SENTRIFIG_USERNAME" => "ops", "SENTRIFIG_PASSWORD" => "pw") do
        config = Configuration.new
        assert_equal "ops", config.username
        assert_equal "pw", config.password
        assert config.credentials_configured?
      end
    end

    test "environment defaults to the environment Sentry reports" do
      previous = Sentry.configuration.environment
      Sentry.configuration.environment = "staging"
      assert_equal "staging", Configuration.new.environment
    ensure
      Sentry.configuration.environment = previous
    end

    test "custom values" do
      config = Configuration.new
      logger = Logger.new(nil)
      config.username = "ops"
      config.password = "pw"
      config.enabled_by_default = false
      config.cache_ttl = 30
      config.environment = "staging"
      config.logger = logger

      assert config.credentials_configured?
      assert_equal false, config.enabled_by_default
      assert_equal 30, config.cache_ttl
      assert_equal "staging", config.environment
      assert_same logger, config.logger
    end

    test "missing or blank credentials are not configured but do not raise" do
      config = Configuration.new
      config.username = "ops"
      assert_not config.credentials_configured?

      config.password = "   "
      assert_not config.credentials_configured?
      assert config.validate!
    end

    test "invalid cache_ttl" do
      config = Configuration.new
      assert_raises(ConfigurationError) { config.cache_ttl = -1 }
      assert_raises(ConfigurationError) { config.cache_ttl = "5" }
      assert_raises(ConfigurationError) { config.cache_ttl = nil }
      assert_equal Configuration::DEFAULT_CACHE_TTL, config.cache_ttl
    end

    test "invalid enabled_by_default" do
      config = Configuration.new
      assert_raises(ConfigurationError) { config.enabled_by_default = nil }
      assert_raises(ConfigurationError) { config.enabled_by_default = "yes" }
    end

    test "invalid environment" do
      config = Configuration.new
      assert_raises(ConfigurationError) { config.environment = "" }
      assert_raises(ConfigurationError) { config.environment = "  " }
    end

    test "invalid credential types fail validation" do
      config = Configuration.new
      config.username = :admin
      config.password = "x"
      assert_raises(ConfigurationError) { config.validate! }
    end

    test "Sentrifig.configure validates and resets the runtime" do
      before = Sentrifig.runtime
      Sentrifig.configure { |c| c.cache_ttl = 1 }
      assert_not_same before, Sentrifig.runtime
      assert_equal 1, Sentrifig.configuration.cache_ttl

      assert_raises(ConfigurationError) { Sentrifig.configure { |c| c.cache_ttl = -1 } }
    end

    test "client_authenticator accepts a lambda, any callable, or nil" do
      config = Configuration.new
      assert_nil config.client_authenticator
      assert_not config.client_authenticator_configured?

      callable = Class.new { def call(_request) = true }.new
      config.client_authenticator = callable
      assert_equal callable, config.client_authenticator
      assert config.client_authenticator_configured?

      config.client_authenticator = ->(_request) { true }
      config.client_authenticator = nil
      assert_nil config.client_authenticator
    end

    test "client_authenticator rejects non-callables and the wrong arity" do
      config = Configuration.new

      assert_raises(ConfigurationError) { config.client_authenticator = "nope" }
      assert_raises(ConfigurationError) { config.client_authenticator = ->(_a, _b) { true } }
    end

    test "client_poll_interval defaults to 60 and must be positive" do
      config = Configuration.new
      assert_equal 60, config.client_poll_interval

      config.client_poll_interval = 120
      assert_equal 120, config.client_poll_interval

      assert_raises(ConfigurationError) { config.client_poll_interval = 0 }
      assert_raises(ConfigurationError) { config.client_poll_interval = -1 }
      assert_raises(ConfigurationError) { config.client_poll_interval = "60" }
    end

    test "validate! passes with no client_authenticator set" do
      config = Configuration.new
      config.environment = "production"

      assert config.validate!
    end
  end
end
