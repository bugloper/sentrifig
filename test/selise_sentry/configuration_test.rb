# frozen_string_literal: true

require "test_helper"

module SeliseSentry
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

    test "credentials default to the SELISE_SENTRY_USERNAME/PASSWORD environment variables" do
      with_env("SELISE_SENTRY_USERNAME" => "ops", "SELISE_SENTRY_PASSWORD" => "pw") do
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

    test "SeliseSentry.configure validates and resets the runtime" do
      before = SeliseSentry.runtime
      SeliseSentry.configure { |c| c.cache_ttl = 1 }
      assert_not_same before, SeliseSentry.runtime
      assert_equal 1, SeliseSentry.configuration.cache_ttl

      assert_raises(ConfigurationError) { SeliseSentry.configure { |c| c.cache_ttl = -1 } }
    end
  end
end
