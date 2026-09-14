# frozen_string_literal: true

require "test_helper"

module SeliseSentry
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    setup do
      Setting.delete_all
      SeliseSentry.reset!
      configure_selise_sentry
    end

    teardown { SeliseSentry.reset! }

    # --- authentication ---------------------------------------------------

    test "unauthenticated request is refused with 401" do
      get "/selise-sentry"
      assert_response :unauthorized
      assert_match(/Basic realm="Selise Sentry"/, response.headers["WWW-Authenticate"])
      assert_no_match(/ENABLED|DISABLED/, response.body)
    end

    test "invalid credentials are refused with 401" do
      get "/selise-sentry", headers: basic_auth("admin", "wrong")
      assert_response :unauthorized
      get "/selise-sentry", headers: basic_auth("nobody", "secret")
      assert_response :unauthorized
    end

    test "valid credentials grant access" do
      get "/selise-sentry", headers: basic_auth
      assert_response :success
    end

    test "state-changing routes require authentication too" do
      post "/selise-sentry/disable"
      assert_response :unauthorized
      assert SeliseSentry.enabled?

      post "/selise-sentry/disable", headers: basic_auth("admin", "wrong")
      assert_response :unauthorized
      assert SeliseSentry.enabled?
    end

    test "when credentials are not configured every route is refused, even with a guess" do
      logger, log = capturing_logger
      configure_selise_sentry(username: nil, password: nil, logger: logger)

      get "/selise-sentry", headers: basic_auth("", "")
      assert_response :unauthorized
      post "/selise-sentry/disable", headers: basic_auth("admin", "secret")
      assert_response :unauthorized
      assert SeliseSentry.enabled?
      assert_includes log.string, "username/password are not configured"
    end

    # --- dashboard ----------------------------------------------------------

    test "dashboard shows environment, ENABLED status and the disable button" do
      get "/selise-sentry", headers: basic_auth
      assert_response :success
      assert_select "h1", "Selise Sentry"
      assert_select ".env", "test"
      assert_select ".status.enabled", text: "ENABLED"
      assert_select "form[action=?][method=post]", "/selise-sentry/disable" do
        assert_select "button", "Disable Sentry"
      end
      assert_select "form[action=?]", "/selise-sentry/enable", count: 0
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_match(/SDK is configured to send/, response.body)
    end

    test "dashboard says when the SDK itself cannot send" do
      Sentry.configuration.dsn = nil
      get "/selise-sentry", headers: basic_auth
      assert_match(/Not sending from this deployment regardless of the switch:\s*DSN not set or not valid/, response.body)
    end

    test "dashboard shows DISABLED status and the enable button" do
      SeliseSentry.disable!(by: "alice")
      get "/selise-sentry", headers: basic_auth
      assert_select ".status.disabled", text: "DISABLED"
      assert_select "form[action=?]", "/selise-sentry/enable"
      assert_match(/by alice/, response.body)
    end

    test "dashboard never exposes the DSN or credentials" do
      get "/selise-sentry", headers: basic_auth
      SeliseSentryTestSupport::DUMMY_DSN_FRAGMENTS.each { |fragment| assert_no_match(/#{fragment}/, response.body) }
      assert_no_match(/secret/, response.body)
    end

    test "dashboard still renders when the database is down" do
      Setting.stub(:where, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "down" }) do
        get "/selise-sentry", headers: basic_auth
      end
      assert_response :success
      assert_select ".status.enabled"
      assert_match(/database is currently unreachable/, response.body)
      assert_no_match(/ConnectionNotEstablished/, response.body)
    end

    # --- state changes ------------------------------------------------------

    test "POST disable turns Sentry off and records the operator" do
      post "/selise-sentry/disable", headers: basic_auth
      assert_redirected_to "/selise-sentry/"
      assert_not SeliseSentry.enabled?
      assert_equal "admin", Setting.find_by!(environment: "test").changed_by

      follow_redirect!(headers: basic_auth)
      assert_select ".flash.notice", /Sentry disabled for test/
      assert_select ".status.disabled"
    end

    test "POST enable turns Sentry back on" do
      SeliseSentry.disable!
      post "/selise-sentry/enable", headers: basic_auth
      assert_redirected_to "/selise-sentry/"
      assert SeliseSentry.enabled?
    end

    test "GET cannot mutate state" do
      get "/selise-sentry/disable", headers: basic_auth
      assert_response :not_found
      assert SeliseSentry.enabled?

      get "/selise-sentry/enable", headers: basic_auth
      assert_response :not_found
    end

    test "PATCH/PUT/DELETE are not routes for state changes" do
      %i[patch put delete].each do |verb|
        public_send(verb, "/selise-sentry/disable", headers: basic_auth)
        assert_response :not_found
      end
      assert SeliseSentry.enabled?
    end

    test "a persistence failure shows an alert and leaves the state unchanged" do
      Setting.stub(:find_or_initialize_by, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "down" }) do
        post "/selise-sentry/disable", headers: basic_auth
      end
      assert_redirected_to "/selise-sentry/"
      assert SeliseSentry.enabled?
      follow_redirect!(headers: basic_auth)
      assert_select ".flash.alert", /could not be saved/
      assert_no_match(/ConnectionNotEstablished/, response.body)
    end

    # --- CSRF ---------------------------------------------------------------

    test "CSRF protection rejects a POST without a token and accepts one with it" do
      with_forgery_protection do
        post "/selise-sentry/disable", headers: basic_auth
        assert_response :unprocessable_content
        assert SeliseSentry.enabled?, "state must not change on a CSRF failure"

        get "/selise-sentry", headers: basic_auth
        assert_response :success
        token = css_select("form[action='/selise-sentry/disable'] input[name=authenticity_token]").first["value"]
        assert token.present?

        post "/selise-sentry/disable", headers: basic_auth, params: { authenticity_token: token }
        assert_redirected_to "/selise-sentry/"
        assert_not SeliseSentry.enabled?
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
