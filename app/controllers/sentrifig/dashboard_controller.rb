# frozen_string_literal: true

module Sentrifig
  class DashboardController < ApplicationController
    def show
      @statuses = Sentrifig.statuses
    end

    def enable
      change(true)
    end

    def disable
      change(false)
    end

    private

    def change(enabled)
      scope = Scope.coerce(params[:scope])

      if enabled
        Sentrifig.enable!(by: current_operator, scope: scope)
      else
        Sentrifig.disable!(by: current_operator, scope: scope)
      end

      redirect_to root_path,
                  notice: "#{scope.capitalize} Sentry #{enabled ? 'enabled' : 'disabled'} " \
                          "for #{Sentrifig.current_environment}."
    rescue Sentrifig::PersistenceError
      # Details are already in the log; keep database errors out of the UI.
      redirect_to root_path,
                  alert: "The change could not be saved because the database is unavailable. Sentry state is unchanged."
    rescue ArgumentError
      # Unreachable through the routes' constraint; defence in depth.
      head :not_found
    end
  end
end
