# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"
require "minitest/mock"
require "sentrifig/test_helper"
require "stringio"

ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new([File.expand_path("../db/migrate", __dir__)]).migrate

module SentrifigTestSupport
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

  def configure_sentrifig(**overrides)
    Sentrifig.configure do |config|
      config.username = overrides.fetch(:username, "admin")
      config.password = overrides.fetch(:password, "secret")
      config.cache_ttl = overrides.fetch(:cache_ttl, 0)
      config.enabled_by_default = overrides[:enabled_by_default] if overrides.key?(:enabled_by_default)
      config.environment = overrides[:environment] if overrides.key?(:environment)
      config.logger = overrides[:logger] if overrides.key?(:logger)
      # Deliberately nil unless asked for: an unprepared test should see the
      # fail-closed path the state endpoint takes when a host forgets the hook.
      config.client_authenticator = overrides[:client_authenticator] if overrides.key?(:client_authenticator)
      config.client_poll_interval = overrides[:client_poll_interval] if overrides.key?(:client_poll_interval)
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

# Sentry's configuration is global, and applying settings mutates it in place.
# Snapshot the pristine values once and restore them between examples, or a test
# that changes sample_rate silently becomes the next test's baseline.
PRISTINE_SENTRY_CONFIG = Sentrifig::Settings::Schema.for_scope(Sentrifig::Scope::BACKEND).to_h do |definition|
  [definition.key, Sentry.configuration.public_send(definition.key)]
end.freeze

class ActiveSupport::TestCase
  include Sentrifig::TestHelper
  include SentrifigTestSupport

  setup do
    Sentrifig::Setting.delete_all
    Sentrifig.reset!
    configure_sentrifig
    setup_sentrifig_test
  end

  teardown do
    teardown_sentrifig_test
    Sentrifig.reset!
    PRISTINE_SENTRY_CONFIG.each do |key, value|
      Sentry.configuration.public_send(:"#{key}=", value.dup)
    rescue StandardError
      Sentry.configuration.public_send(:"#{key}=", value)
    end
  end
end

class ActionDispatch::IntegrationTest
  include SentrifigTestSupport
end
