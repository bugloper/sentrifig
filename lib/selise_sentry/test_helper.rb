# frozen_string_literal: true

require "sentry/test_helper"

module SeliseSentry
  # Test support for applications that use selise-sentry. Builds on
  # Sentry::TestHelper (dummy DSN + Sentry::DummyTransport, so nothing leaves
  # the process) and adds what the switch needs:
  #
  # - the in-process cache is reset around every test, so the persisted state
  #   is re-read instead of leaking between examples through the TTL snapshot;
  # - the gate is re-installed after setup, because
  #   Sentry::TestHelper#teardown_sentry_test clears *all* global event
  #   processors and would otherwise remove the switch for later tests.
  #
  # Minitest:
  #
  #   include SeliseSentry::TestHelper
  #   setup    { setup_selise_sentry_test }
  #   teardown { teardown_selise_sentry_test }
  #
  # RSpec: `require "selise_sentry/rspec"` and tag examples with :selise_sentry.
  module TestHelper
    include Sentry::TestHelper

    # @yieldparam config [Sentry::Configuration] the dummy configuration, as in setup_sentry_test
    def setup_selise_sentry_test(&block)
      SeliseSentry.runtime.reset!
      setup_sentry_test(&block)
      SeliseSentry.install!
    end

    def teardown_selise_sentry_test
      teardown_sentry_test
      SeliseSentry.runtime.reset!
    end

    # Error/message events only; requests also produce TransactionEvents when tracing is on.
    def sentry_error_events
      sentry_events.select { |event| event.is_a?(Sentry::ErrorEvent) }
    end

    # Temporarily sets the UI credentials, restoring the previous ones afterwards.
    def with_selise_sentry_credentials(username, password)
      config = SeliseSentry.configuration
      previous = [config.username, config.password]
      config.username = username
      config.password = password
      yield
    ensure
      config.username, config.password = previous
    end

    # Headers for an authenticated request to the mounted UI.
    def selise_sentry_basic_auth(username, password)
      { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }
    end
  end
end
