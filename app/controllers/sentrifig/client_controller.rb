# frozen_string_literal: true

module Sentrifig
  # Base class for the endpoints a browser calls.
  #
  # Deliberately NOT a subclass of Sentrifig::ApplicationController. A browser
  # cannot hold the operator HTTP Basic credentials, so the operator auth chain
  # must not be in this class's ancestry at all: `skip_before_action
  # :authenticate!` would leave it one edit -- or one new before_action on the
  # parent -- away from re-attaching, and would keep `protect_from_forgery with:
  # :exception` and the HTML layout on a JSON GET that has neither.
  #
  # ActionController::API also means no cookie/session middleware, no view
  # lookup and no flash, so nothing here can accidentally render the dashboard.
  class ClientController < ::ActionController::API
    before_action :authenticate_client!
    after_action :forbid_caching

    private

    def authenticate_client!
      authenticator = Sentrifig.configuration.client_authenticator

      if authenticator.nil?
        Sentrifig.logger.error(
          "[sentrifig] refusing request to #{request.path}: config.client_authenticator is not set, " \
          "so no browser client can be authenticated (see Sentrifig.configure)"
        )
        return refuse
      end

      refuse unless authenticator.call(request)
    rescue StandardError => e
      # Fail closed, but never 500: a broken host authenticator must not turn
      # into a Sentry event storm from the very endpoint that gates Sentry.
      Sentrifig.logger.error(
        "[sentrifig] client_authenticator raised #{e.class}: #{e.message}; refusing #{request.path}"
      )
      refuse
    end

    def refuse
      # No WWW-Authenticate. A challenge header on an XHR the user never
      # initiated makes the browser pop its native Basic-auth dialog.
      response.headers.delete("WWW-Authenticate")
      render json: { error: "unauthorized" }, status: :unauthorized
    end

    def forbid_caching
      response.headers["Cache-Control"] = "no-store"
    end
  end
end
