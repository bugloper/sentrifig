# frozen_string_literal: true

require "digest"

module SeliseSentry
  class ApplicationController < ::ActionController::Base
    REALM = "Selise Sentry"

    protect_from_forgery with: :exception

    before_action :authenticate!
    after_action :forbid_caching

    layout "selise_sentry/application"

    private

    def authenticate!
      config = SeliseSentry.configuration

      unless config.credentials_configured?
        SeliseSentry.logger.error(
          "[selise-sentry] refusing request to #{request.path}: username/password are not configured " \
          "(see SeliseSentry.configure)"
        )
        return request_http_basic_authentication(REALM)
      end

      authenticate_or_request_with_http_basic(REALM) do |username, password|
        # Non-short-circuit & so both comparisons always run.
        secure_equal?(username, config.username) & secure_equal?(password, config.password)
      end
    end

    # Hash both sides before comparing so the comparison is constant time regardless of
    # length. A bare secure_compare short-circuits on a length mismatch, which would reveal
    # the length of the configured credentials.
    def secure_equal?(given, expected)
      ActiveSupport::SecurityUtils.secure_compare(
        ::Digest::SHA256.hexdigest(given.to_s),
        ::Digest::SHA256.hexdigest(expected.to_s)
      )
    end

    def current_operator
      return nil unless request.authorization

      ActionController::HttpAuthentication::Basic.user_name_and_password(request).first
    end

    def forbid_caching
      response.headers["Cache-Control"] = "no-store"
    end
  end
end
