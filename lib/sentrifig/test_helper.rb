# frozen_string_literal: true

require "sentry/test_helper"

module Sentrifig
  # Test support for applications that use sentrifig. Builds on
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
  #   include Sentrifig::TestHelper
  #   setup    { setup_sentrifig_test }
  #   teardown { teardown_sentrifig_test }
  #
  # RSpec: `require "sentrifig/rspec"` and tag examples with :sentrifig.
  module TestHelper
    include Sentry::TestHelper

    # @yieldparam config [Sentry::Configuration] the dummy configuration, as in setup_sentry_test
    def setup_sentrifig_test(&block)
      Sentrifig.runtimes.each_value(&:reset!)
      setup_sentry_test(&block)
      Sentrifig.install!
    end

    def teardown_sentrifig_test
      teardown_sentry_test
      Sentrifig.runtimes.each_value(&:reset!)
    end

    # Error/message events only; requests also produce TransactionEvents when tracing is on.
    def sentry_error_events
      sentry_events.select { |event| event.is_a?(Sentry::ErrorEvent) }
    end

    # Temporarily sets the UI credentials, restoring the previous ones afterwards.
    def with_sentrifig_credentials(username, password)
      config = Sentrifig.configuration
      previous = [config.username, config.password]
      config.username = username
      config.password = password
      yield
    ensure
      config.username, config.password = previous
    end

    # Installs a client authenticator for the block, so tests can reach the
    # browser state endpoint. Defaults to allowing every request.
    def with_sentrifig_client_authenticator(callable = ->(_request) { true })
      config = Sentrifig.configuration
      previous = config.client_authenticator
      config.client_authenticator = callable
      yield
    ensure
      config.client_authenticator = previous
    end

    # Headers for an authenticated request to the mounted UI.
    def sentrifig_basic_auth(username, password)
      { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }
    end
  end
end
