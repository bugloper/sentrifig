# frozen_string_literal: true

module SeliseSentry
  class DashboardController < ApplicationController
    def show
      @status = SeliseSentry.status
    end

    def enable
      change(true)
    end

    def disable
      change(false)
    end

    private

    def change(enabled)
      if enabled
        SeliseSentry.enable!(by: current_operator)
      else
        SeliseSentry.disable!(by: current_operator)
      end

      redirect_to root_path,
                  notice: "Sentry #{enabled ? 'enabled' : 'disabled'} for #{SeliseSentry.current_environment}."
    rescue SeliseSentry::PersistenceError
      # Details are already in the log; keep database errors out of the UI.
      redirect_to root_path,
                  alert: "The change could not be saved because the database is unavailable. Sentry state is unchanged."
    end
  end
end
