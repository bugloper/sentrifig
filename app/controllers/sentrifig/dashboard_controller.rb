# frozen_string_literal: true

module Sentrifig
  class DashboardController < ApplicationController
    def show
      @status = Sentrifig.status
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
        Sentrifig.enable!(by: current_operator)
      else
        Sentrifig.disable!(by: current_operator)
      end

      redirect_to root_path,
                  notice: "Sentry #{enabled ? 'enabled' : 'disabled'} for #{Sentrifig.current_environment}."
    rescue Sentrifig::PersistenceError
      # Details are already in the log; keep database errors out of the UI.
      redirect_to root_path,
                  alert: "The change could not be saved because the database is unavailable. Sentry state is unchanged."
    end
  end
end
