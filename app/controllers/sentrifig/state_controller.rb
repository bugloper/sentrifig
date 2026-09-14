# frozen_string_literal: true

module Sentrifig
  # GET <mount>/state -- the frontend switch, for browser Sentry SDKs.
  #
  # The body is an explicit allow-list, never status.to_h. This endpoint is
  # readable by every logged-in application user; the dashboard is not. In
  # particular it never carries changed_by, which is the operator's HTTP Basic
  # *username* -- half of a static credential pair guarding a dashboard with no
  # lockout, no rotation and no MFA. changed_at, sdk_ready and sdk_problems are
  # left out too: useless to a browser, and sdk_problems is DSN-shaped text.
  class StateController < ClientController
    def show
      status = Sentrifig.status(Scope::FRONTEND)

      render json: {
        enabled: status.enabled?,
        scope: Scope::FRONTEND,
        environment: status.environment,
        source: status.source.to_s,
        poll_interval: Sentrifig.configuration.client_poll_interval
      }
    end
  end
end
