# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "sentry-ruby"
require "sentry-rails"
require "selise_sentry"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.logger = ActiveSupport::Logger.new(File.expand_path("../log/#{Rails.env}.log", __dir__))
    config.log_level = :debug
    config.hosts.clear
    config.secret_key_base = "dummy-secret-key-base-for-selise-sentry-tests-only-not-secret"
  end
end
