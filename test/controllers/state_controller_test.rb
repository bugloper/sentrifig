# frozen_string_literal: true

require "test_helper"

module Sentrifig
  class StateControllerTest < ActionDispatch::IntegrationTest
    ALLOW = ->(_request) { true }

    def json = JSON.parse(response.body)

    # --- authentication -----------------------------------------------------

    test "refuses every request when no client_authenticator is configured" do
      logger, log = capturing_logger
      configure_sentrifig(logger: logger)

      get "/sentrifig/state"

      assert_response :unauthorized
      assert_equal({ "error" => "unauthorized" }, json)
      assert_includes log.string, "client_authenticator is not set"
    end

    test "refuses when the authenticator returns false" do
      configure_sentrifig(client_authenticator: ->(_request) { false })

      get "/sentrifig/state"

      assert_response :unauthorized
    end

    test "refuses when the authenticator returns nil" do
      configure_sentrifig(client_authenticator: ->(_request) { nil })

      get "/sentrifig/state"

      assert_response :unauthorized
    end

    test "an authenticator that raises is a 401, not a 500" do
      logger, log = capturing_logger
      configure_sentrifig(logger: logger, client_authenticator: ->(_request) { raise "boom" })

      get "/sentrifig/state"

      assert_response :unauthorized
      assert_includes log.string, "client_authenticator raised RuntimeError: boom"
    end

    # The regression test for the controller hierarchy: the operator credentials
    # guard the dashboard and must never be a way into the browser endpoint.
    test "operator Basic credentials alone do not grant access" do
      get "/sentrifig/state", headers: basic_auth

      assert_response :unauthorized
    end

    test "a 401 carries no WWW-Authenticate, so no browser login dialog appears" do
      get "/sentrifig/state"

      assert_response :unauthorized
      assert_nil response.headers["WWW-Authenticate"]
    end

    test "the authenticator receives the request, with headers and cookies" do
      seen = nil
      configure_sentrifig(client_authenticator: lambda { |request|
        seen = request
        true
      })

      get "/sentrifig/state",
          headers: { "Authorization" => "Bearer token.value.here", "Cookie" => "_session=abc" }

      assert_response :success
      assert_kind_of ActionDispatch::Request, seen
      assert_equal "Bearer token.value.here", seen.headers["Authorization"]
      assert_includes seen.env["HTTP_COOKIE"], "_session=abc"
    end

    # --- the contract -------------------------------------------------------

    test "returns exactly the documented keys and nothing else" do
      configure_sentrifig(client_authenticator: ALLOW)

      get "/sentrifig/state"

      assert_response :success
      assert_equal %w[enabled environment poll_interval scope source], json.keys.sort
    end

    test "never leaks the operator username, timestamps, or SDK diagnostics" do
      configure_sentrifig(client_authenticator: ALLOW)
      Sentrifig.disable!(by: "an-operator-username", scope: Scope::FRONTEND)

      get "/sentrifig/state"

      assert_response :success
      assert_not_includes response.body, "an-operator-username"
      %w[changed_by changed_at sdk_ready sdk_problems secret].each do |forbidden|
        assert_not_includes response.body, forbidden
      end
      DUMMY_DSN_FRAGMENTS.each { |fragment| assert_not_includes response.body, fragment }
    end

    test "serves JSON with no-store" do
      configure_sentrifig(client_authenticator: ALLOW)

      get "/sentrifig/state"

      assert_match %r{\Aapplication/json}, response.media_type || response.content_type
      assert_equal "no-store", response.headers["Cache-Control"]
    end

    test "publishes the configured poll interval, not cache_ttl" do
      configure_sentrifig(client_authenticator: ALLOW, cache_ttl: 5, client_poll_interval: 120)

      get "/sentrifig/state"

      assert_equal 120, json["poll_interval"]
    end

    # --- scope isolation ----------------------------------------------------

    test "reports the frontend switch, and disabling it leaves the backend alone" do
      configure_sentrifig(client_authenticator: ALLOW)

      get "/sentrifig/state"
      assert_equal true, json["enabled"]

      Sentrifig.disable!(by: "operator", scope: Scope::FRONTEND)

      get "/sentrifig/state"
      assert_equal false, json["enabled"]
      assert_equal "frontend", json["scope"]
      assert Sentrifig.enabled?, "the backend switch must be untouched"
    end

    test "disabling the backend does not silence browser clients" do
      configure_sentrifig(client_authenticator: ALLOW)
      Sentrifig.disable!(by: "operator")

      get "/sentrifig/state"

      assert_equal true, json["enabled"]
      assert_not Sentrifig.enabled?
    end

    test "reports the source so a client can tell a default from stale state" do
      configure_sentrifig(client_authenticator: ALLOW)

      get "/sentrifig/state"
      assert_equal "default", json["source"]

      Sentrifig.enable!(by: "operator", scope: Scope::FRONTEND)

      get "/sentrifig/state"
      assert_equal "database", json["source"]
    end

    test "a database outage is a 200 marked fallback, never a 5xx" do
      configure_sentrifig(client_authenticator: ALLOW)
      failing = ->(*) { raise ActiveRecord::ConnectionNotEstablished, "db down" }

      Setting.stub(:where, failing) do
        get "/sentrifig/state"
      end

      assert_response :success
      assert_equal "fallback", json["source"]
      assert_equal true, json["enabled"]
      assert_not_includes response.body, "ConnectionNotEstablished"
    end

    # --- routing ------------------------------------------------------------

    test "only GET is routed" do
      configure_sentrifig(client_authenticator: ALLOW)

      %i[post put patch delete].each do |verb|
        public_send(verb, "/sentrifig/state")
        assert_response :not_found, "#{verb.upcase} must not be routed"
      end
    end

    test "the read path needs no CSRF token" do
      configure_sentrifig(client_authenticator: ALLOW)

      with_forgery_protection do
        get "/sentrifig/state"
      end

      assert_response :success
    end

    private

    def with_forgery_protection
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end
  end
end
