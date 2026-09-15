# frozen_string_literal: true

require "test_helper"

module Sentrifig
  class SettingsControllerTest < ActionDispatch::IntegrationTest
    # --- authentication ------------------------------------------------------

    test "editing settings needs the operator credentials" do
      post "/sentrifig/backend/settings", params: { settings: { sample_rate: "0.5" } }

      assert_response :unauthorized
      assert_in_delta 1.0, Sentrifig.settings[:sample_rate]
    end

    test "resetting needs the operator credentials" do
      Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "0.5" }, by: "alice")

      post "/sentrifig/backend/settings/sample_rate/reset"

      assert_response :unauthorized
      assert_in_delta 0.5, Sentrifig.settings[:sample_rate]
    end

    # --- saving --------------------------------------------------------------

    test "saves a change and records the operator" do
      post "/sentrifig/backend/settings", headers: basic_auth,
                                          params: { settings: { sample_rate: "0.5" } }

      assert_redirected_to "/sentrifig/"
      assert_in_delta 0.5, Sentrifig.settings[:sample_rate]
      assert_equal "admin", Setting.find_by!(environment: "test", scope: Scope::BACKEND).changed_by
    end

    test "an unchecked checkbox stores false rather than being ignored" do
      Sentrifig.update_settings!(Scope::BACKEND, { include_local_variables: "true" }, by: "alice")

      # A browser submits only the hidden field when the box is unchecked.
      post "/sentrifig/backend/settings", headers: basic_auth,
                                          params: { settings: { include_local_variables: "false" } }

      assert_equal false, Sentrifig.settings[:include_local_variables]
    end

    test "a checked checkbox stores true" do
      post "/sentrifig/backend/settings", headers: basic_auth,
                                          params: { settings: { send_default_pii: "true" } }

      assert_equal true, Sentrifig.settings[:send_default_pii]
    end

    test "a list is split from the comma-separated field" do
      post "/sentrifig/backend/settings", headers: basic_auth,
                                          params: { settings: { excluded_exceptions: "A::B, C::D" } }

      assert_equal %w[A::B C::D], Sentrifig.settings[:excluded_exceptions]
    end

    test "an invalid value saves nothing and says why" do
      post "/sentrifig/backend/settings", headers: basic_auth,
                                          params: { settings: { sample_rate: "7" } }

      assert_redirected_to "/sentrifig/"
      follow_redirect!(headers: basic_auth)
      assert_select ".flash.alert", /sample_rate must be between 0.0 and 1.0/
      assert_equal 0, Setting.count
    end

    test "one bad field rejects the whole form" do
      post "/sentrifig/backend/settings", headers: basic_auth,
                                          params: { settings: { sample_rate: "0.5", max_breadcrumbs: "loads" } }

      assert_in_delta 1.0, Sentrifig.settings[:sample_rate]
      assert_equal 0, Setting.count
    end

    test "a key from the other scope is refused" do
      post "/sentrifig/frontend/settings", headers: basic_auth,
                                          params: { settings: { excluded_exceptions: "A::B" } }

      # Filtered out before it reaches the schema, so the submission is a no-op
      # rather than an error the operator cannot act on.
      assert_redirected_to "/sentrifig/"
      assert_empty Sentrifig.runtime(Scope::FRONTEND).overridden_keys
    end

    test "an unknown scope is a 404" do
      post "/sentrifig/sideways/settings", headers: basic_auth, params: { settings: { sample_rate: "0.5" } }

      assert_response :not_found
    end

    test "a database failure reports it and changes nothing" do
      failing = ->(*) { raise ActiveRecord::ConnectionNotEstablished, "db down" }

      Setting.stub(:find_or_initialize_by, failing) do
        post "/sentrifig/backend/settings", headers: basic_auth, params: { settings: { sample_rate: "0.5" } }
      end

      assert_redirected_to "/sentrifig/"
      follow_redirect!(headers: basic_auth)
      assert_select ".flash.alert", /database is unavailable/
      assert_no_match(/ConnectionNotEstablished/, response.body)
    end

    # --- resetting -----------------------------------------------------------

    test "resets one setting and leaves the others alone" do
      Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "0.5", max_breadcrumbs: "10" }, by: "alice")

      post "/sentrifig/backend/settings/sample_rate/reset", headers: basic_auth

      assert_redirected_to "/sentrifig/"
      assert_in_delta 1.0, Sentrifig.settings[:sample_rate]
      assert_equal 10, Sentrifig.settings[:max_breadcrumbs]
    end

    test "resetting an unknown key is refused" do
      post "/sentrifig/backend/settings/nonsense/reset", headers: basic_auth

      assert_redirected_to "/sentrifig/"
      follow_redirect!(headers: basic_auth)
      assert_select ".flash.alert", /not a setting for the backend scope/
    end

    # --- the rendered form ---------------------------------------------------

    test "the dashboard renders a typed input per setting" do
      get "/sentrifig", headers: basic_auth

      assert_response :success
      assert_select "form[action=?]", "/sentrifig/backend/settings"
      assert_select "form[action=?]", "/sentrifig/frontend/settings"
      assert_select "input[name=?][type=?]", "settings[sample_rate]", "number"
      assert_select "input[name=?][type=?]", "settings[send_default_pii]", "checkbox"
      # A 20-entry list is unreadable in a one-line input.
      assert_select "textarea[name=?]", "settings[excluded_exceptions]"
      # Bounds reach the browser as well as the server.
      assert_select "input[name=?][min=?][max=?]", "settings[sample_rate]", "0.0", "1.0"
      assert_select "input[name=?][max=?]", "settings[max_breadcrumbs]", "100"
    end

    test "an overridden setting is marked, and offers a reset" do
      Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "0.5" }, by: "alice")

      get "/sentrifig", headers: basic_auth

      assert_select ".setting.overridden label", "sample_rate"
      # The reset is a submit button with formaction, so it lives inside the
      # settings form rather than nesting a second form inside it.
      assert_select "button[formaction=?]", "/sentrifig/backend/settings/sample_rate/reset"
      assert_select "form form", count: 0, message: "nested forms are invalid HTML"
    end

    test "a setting following an environment variable says so" do
      with_env("SENTRY_SAMPLE_RATE" => "0.25") do
        get "/sentrifig", headers: basic_auth
      end

      assert_select ".origin", /default from SENTRY_SAMPLE_RATE/
    end

    test "settings changes are CSRF protected" do
      with_forgery_protection do
        post "/sentrifig/backend/settings", headers: basic_auth, params: { settings: { sample_rate: "0.5" } }

        assert_response :unprocessable_content
        assert_equal 0, Setting.count
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
