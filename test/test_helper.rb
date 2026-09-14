# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"
require "minitest/mock"
require "selise_sentry/test_helper"
require "stringio"

ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new([File.expand_path("../db/migrate", __dir__)]).migrate

module SeliseSentryTestSupport
  DUMMY_DSN_FRAGMENTS = %w[12345 67890 sentry.localdomain].freeze

  def basic_auth(username = "admin", password = "secret")
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }
  end

  # Sets environment variables for the block and restores them afterwards.
  def with_env(pairs)
    previous = pairs.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def configure_selise_sentry(**overrides)
    SeliseSentry.configure do |config|
      config.username = overrides.fetch(:username, "admin")
      config.password = overrides.fetch(:password, "secret")
      config.cache_ttl = overrides.fetch(:cache_ttl, 0)
      config.enabled_by_default = overrides[:enabled_by_default] if overrides.key?(:enabled_by_default)
      config.environment = overrides[:environment] if overrides.key?(:environment)
      config.logger = overrides[:logger] if overrides.key?(:logger)
    end
  end

  # Logger writing to a StringIO so tests can assert on log lines.
  def capturing_logger
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.formatter = ->(_sev, _time, _prog, msg) { "#{msg}\n" }
    [logger, io]
  end
end

class ActiveSupport::TestCase
  include SeliseSentry::TestHelper
  include SeliseSentryTestSupport

  setup do
    SeliseSentry::Setting.delete_all
    SeliseSentry.reset!
    configure_selise_sentry
    setup_selise_sentry_test
  end

  teardown do
    teardown_selise_sentry_test
    SeliseSentry.reset!
  end
end

class ActionDispatch::IntegrationTest
  include SeliseSentryTestSupport
end
