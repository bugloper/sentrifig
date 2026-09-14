# frozen_string_literal: true

require "test_helper"

module Sentrifig
  class TestHelperTest < ActiveSupport::TestCase
    test "setup re-installs the gate after Sentry's helper cleared global processors" do
      Sentry::Scope.global_event_processors.clear
      assert_not Gate.installed?

      teardown_sentrifig_test
      setup_sentrifig_test

      assert Gate.installed?
      assert_equal 1, Sentry::Scope.global_event_processors.count(Gate::PROCESSOR)
    end

    test "setup resets the runtime cache so persisted state is re-read" do
      configure_sentrifig(cache_ttl: 300)
      assert Sentrifig.enabled?
      Setting.create!(environment: Sentrifig.current_environment, enabled: false)
      assert Sentrifig.enabled?, "cached"

      teardown_sentrifig_test
      setup_sentrifig_test
      assert_not Sentrifig.enabled?
    end

    test "sentry_error_events filters out transactions" do
      Sentry.capture_message("m")
      Sentry.start_transaction(name: "t", op: "x").finish
      assert_equal 2, sentry_events.size
      assert_equal ["m"], sentry_error_events.map(&:message)
    end

    test "with_sentrifig_credentials restores previous values" do
      with_sentrifig_credentials("u", "p") do
        assert_equal "u", Sentrifig.configuration.username
      end
      assert_equal "admin", Sentrifig.configuration.username
      headers = sentrifig_basic_auth("u", "p")
      assert_match(/\ABasic /, headers["Authorization"])
    end
  end
end
