# frozen_string_literal: true

class DemoController < ActionController::Base
  def ok
    render plain: "ok"
  end

  # Manual capture. Sentry returns the event when it was accepted and nil
  # when the gate discarded it, which makes the switch observable via curl.
  def capture
    event = Sentry.capture_message("manual capture from the demo app")
    render plain: event ? "captured event #{event.event_id}" : "dropped by sentrifig"
  end

  # Unhandled exception: captured by Sentry::Rails::CaptureExceptions.
  def boom
    raise "boom from the demo app"
  end

  # Handled error via Rails' error reporter (Sentry::Rails::ErrorSubscriber).
  def report
    Rails.error.report(RuntimeError.new("reported from the demo app"), handled: true)
    render plain: "reported"
  end
end
