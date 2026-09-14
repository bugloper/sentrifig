# frozen_string_literal: true

require "test_helper"
require "open3"

module SeliseSentry
  class GateTest < ActiveSupport::TestCase
    test "install! is idempotent" do
      Gate.uninstall!
      assert_not Gate.installed?

      assert Gate.install!
      assert_not Gate.install!
      assert Gate.installed?
      assert_equal 1, Sentry::Scope.global_event_processors.count(Gate::PROCESSOR)
    end

    # A fresh process, no test helpers involved: proves the engine wiring for both the gate and
    # the gem-owned Sentry.init (defaults + the dummy app's overrides).
    test "the engine installs the gate and initialises Sentry at boot without any application code" do
      script = <<~RUBY
        require File.expand_path("test/dummy/config/environment", Dir.pwd)
        config = Sentry.configuration
        puts SeliseSentry::Gate.installed?
        puts Sentry::Scope.global_event_processors.count(SeliseSentry::Gate::PROCESSOR)
        puts Sentry.initialized?
        puts config.before_send.equal?(SeliseSentry::SentrySetup::STRIP_AUTHORIZATION)
        puts config.rails.structured_logging.enabled.inspect
        puts config.enabled_environments.include?("development")
        puts config.background_worker_threads
      RUBY
      output, status = Open3.capture2e({ "RAILS_ENV" => "test" }, "bundle", "exec", "ruby", "-e", script,
                                       chdir: File.expand_path("../..", __dir__))
      assert status.success?, output
      assert_equal %w[true 1 true true false true 0], output.lines.last(7).map(&:strip)
    end

    test "processor passes events through when enabled" do
      event = Sentry.get_current_client.event_from_message("hi")
      assert_same event, Gate::PROCESSOR.call(event, {})
    end

    test "processor discards events when disabled" do
      SeliseSentry.disable!
      event = Sentry.get_current_client.event_from_message("hi")
      assert_nil Gate::PROCESSOR.call(event, {})
    end

    test "processor fails open and logs once if the runtime blows up" do
      logger, log = capturing_logger
      configure_selise_sentry(logger: logger)
      Gate.uninstall!
      Gate.install!
      event = Sentry.get_current_client.event_from_message("hi")

      SeliseSentry.stub(:enabled?, -> { raise "unexpected" }) do
        assert_same event, Gate::PROCESSOR.call(event, {})
        assert_same event, Gate::PROCESSOR.call(event, {})
      end

      assert_equal 1, log.string.scan("gate error, passing event through").size
    end
  end
end
