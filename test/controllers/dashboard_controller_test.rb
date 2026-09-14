# frozen_string_literal: true

require "test_helper"

module Sentrifig
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    setup do
      Setting.delete_all
      Sentrifig.reset!
      configure_sentrifig
    end

    teardown { Sentrifig.reset! }

    # --- authentication ---------------------------------------------------

    test "unauthenticated request is refused with 401" do
      get "/sentrifig"
      assert_response :unauthorized
      assert_match(/Basic realm="Sentrifig"/, response.headers["WWW-Authenticate"])
      assert_no_match(/ENABLED|DISABLED/, response.body)
    end

    test "invalid credentials are refused with 401" do
      get "/sentrifig", headers: basic_auth("admin", "wrong")
      assert_response :unauthorized
      get "/sentrifig", headers: basic_auth("nobody", "secret")
      assert_response :unauthorized
    end

    test "valid credentials grant access" do
      get "/sentrifig", headers: basic_auth
      assert_response :success
    end

    test "state-changing routes require authentication too" do
      post "/sentrifig/disable"
      assert_response :unauthorized
      assert Sentrifig.enabled?

      post "/sentrifig/disable", headers: basic_auth("admin", "wrong")
      assert_response :unauthorized
      assert Sentrifig.enabled?
    end

    test "when credentials are not configured every route is refused, even with a guess" do
      logger, log = capturing_logger
      configure_sentrifig(username: nil, password: nil, logger: logger)

      get "/sentrifig", headers: basic_auth("", "")
      assert_response :unauthorized
      post "/sentrifig/disable", headers: basic_auth("admin", "secret")
      assert_response :unauthorized
      assert Sentrifig.enabled?
      assert_includes log.string, "username/password are not configured"
    end

    # --- dashboard ----------------------------------------------------------

    test "dashboard shows environment, ENABLED status and the disable button" do
      get "/sentrifig", headers: basic_auth
      assert_response :success
      assert_select "h1", "Sentrifig"
      assert_select ".env", "test"
      assert_select ".status.enabled", text: "ENABLED"
      assert_select "form[action=?][method=post]", "/sentrifig/disable" do
        assert_select "button", "Disable Sentry"
      end
      assert_select "form[action=?]", "/sentrifig/enable", count: 0
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_match(/SDK is configured to send/, response.body)
    end

    test "dashboard says when the SDK itself cannot send" do
      Sentry.configuration.dsn = nil
      get "/sentrifig", headers: basic_auth
      assert_match(/Not sending from this deployment regardless of the switch:\s*DSN not set or not valid/, response.body)
    end

    test "dashboard shows DISABLED status and the enable button" do
      Sentrifig.disable!(by: "alice")
      get "/sentrifig", headers: basic_auth
      assert_select ".status.disabled", text: "DISABLED"
      assert_select "form[action=?]", "/sentrifig/enable"
      assert_match(/by alice/, response.body)
    end

    test "dashboard never exposes the DSN or credentials" do
      get "/sentrifig", headers: basic_auth
      SentrifigTestSupport::DUMMY_DSN_FRAGMENTS.each { |fragment| assert_no_match(/#{fragment}/, response.body) }
      assert_no_match(/secret/, response.body)
    end

    test "dashboard still renders when the database is down" do
      Setting.stub(:where, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "down" }) do
        get "/sentrifig", headers: basic_auth
      end
      assert_response :success
      assert_select ".status.enabled"
      assert_match(/database is currently unreachable/, response.body)
      assert_no_match(/ConnectionNotEstablished/, response.body)
    end

    # --- state changes ------------------------------------------------------

    test "POST disable turns Sentry off and records the operator" do
      post "/sentrifig/disable", headers: basic_auth
      assert_redirected_to "/sentrifig/"
      assert_not Sentrifig.enabled?
      assert_equal "admin", Setting.find_by!(environment: "test").changed_by

      follow_redirect!(headers: basic_auth)
      assert_select ".flash.notice", /Sentry disabled for test/
      assert_select ".status.disabled"
    end

    test "POST enable turns Sentry back on" do
      Sentrifig.disable!
      post "/sentrifig/enable", headers: basic_auth
      assert_redirected_to "/sentrifig/"
      assert Sentrifig.enabled?
    end

    test "GET cannot mutate state" do
      get "/sentrifig/disable", headers: basic_auth
      assert_response :not_found
      assert Sentrifig.enabled?

      get "/sentrifig/enable", headers: basic_auth
      assert_response :not_found
    end

    test "PATCH/PUT/DELETE are not routes for state changes" do
      %i[patch put delete].each do |verb|
        public_send(verb, "/sentrifig/disable", headers: basic_auth)
        assert_response :not_found
      end
      assert Sentrifig.enabled?
    end

    test "a persistence failure shows an alert and leaves the state unchanged" do
      Setting.stub(:find_or_initialize_by, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "down" }) do
        post "/sentrifig/disable", headers: basic_auth
      end
      assert_redirected_to "/sentrifig/"
      assert Sentrifig.enabled?
      follow_redirect!(headers: basic_auth)
      assert_select ".flash.alert", /could not be saved/
      assert_no_match(/ConnectionNotEstablished/, response.body)
    end

    # --- CSRF ---------------------------------------------------------------

    test "CSRF protection rejects a POST without a token and accepts one with it" do
      with_forgery_protection do
        post "/sentrifig/disable", headers: basic_auth
        assert_response :unprocessable_content
        assert Sentrifig.enabled?, "state must not change on a CSRF failure"

        get "/sentrifig", headers: basic_auth
        assert_response :success
        token = css_select("form[action='/sentrifig/disable'] input[name=authenticity_token]").first["value"]
        assert token.present?

        post "/sentrifig/disable", headers: basic_auth, params: { authenticity_token: token }
        assert_redirected_to "/sentrifig/"
        assert_not Sentrifig.enabled?
      end
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
