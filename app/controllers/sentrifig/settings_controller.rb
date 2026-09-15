# frozen_string_literal: true

module Sentrifig
  # Editing the runtime settings behind the two switches.
  #
  # Same operator Basic Auth and CSRF as the dashboard -- these change what a
  # deployment reports to Sentry, so they are not a lower-privilege surface.
  class SettingsController < ApplicationController
    def update
      scope = Scope.coerce(params[:scope])
      Sentrifig.update_settings!(scope, submitted(scope), by: current_operator)

      redirect_to root_path, notice: "#{scope.capitalize} settings saved."
    rescue Sentrifig::ValidationError => e
      # The messages name the offending keys and say what was expected, so they
      # are worth showing rather than a generic "invalid input".
      redirect_to root_path, alert: "Nothing was saved: #{e.message}."
    rescue Sentrifig::PersistenceError
      redirect_to root_path,
                  alert: "The change could not be saved because the database is unavailable. Settings are unchanged."
    rescue ArgumentError
      head :not_found
    end

    def reset
      scope = Scope.coerce(params[:scope])
      Sentrifig.reset_setting!(scope, params[:key], by: current_operator)

      redirect_to root_path, notice: "#{params[:key]} reset to its default."
    rescue Sentrifig::ValidationError => e
      redirect_to root_path, alert: e.message
    rescue Sentrifig::PersistenceError
      redirect_to root_path,
                  alert: "The change could not be saved because the database is unavailable. Settings are unchanged."
    rescue ArgumentError
      head :not_found
    end

    private

    # An unchecked checkbox submits nothing, so booleans are read from their
    # paired hidden field and every schema key is always present.
    def submitted(scope)
      raw = params.fetch(:settings, {})
      raw = raw.permit!.to_h if raw.respond_to?(:permit!)

      Settings::Schema.for_scope(scope).each_with_object({}) do |definition, input|
        key = definition.key.to_s
        next unless raw.key?(key)

        input[definition.key] = raw[key]
      end
    end
  end
end
