# frozen_string_literal: true

module Sentrifig
  # The data-plane hook into Sentry.
  #
  # A single global event processor is registered with sentry-ruby. Global
  # event processors run inside Sentry::Scope#apply_to_event for every
  # ErrorEvent (capture_exception / capture_message / Rails exceptions),
  # TransactionEvent (performance) and CheckInEvent (crons), before the
  # application's own before_send callbacks. Returning nil discards the event;
  # Sentry records it as a lost event with reason :event_processor.
  #
  # Global processors live on Sentry::Scope (class level), so the gate does not
  # depend on when or how often Sentry.init runs and never touches the
  # application's Sentry configuration object.
  module Gate
    PROCESSOR = lambda do |event, _hint|
      Sentrifig.enabled? ? event : nil
    rescue StandardError => e
      # Runtime already degrades gracefully; this is a last line of defence.
      # Fail open: never let the switch itself lose an event.
      Gate.report_failure(e)
      event
    end

    @failure_reported = false

    class << self
      # Idempotent. Returns true when the processor was installed by this call.
      def install!
        return false if installed?

        Sentry.add_global_event_processor(&PROCESSOR)
        true
      end

      def installed?
        Sentry::Scope.global_event_processors.include?(PROCESSOR)
      end

      # Intended for tests.
      def uninstall!
        Sentry::Scope.global_event_processors.delete(PROCESSOR)
        @failure_reported = false
        nil
      end

      # @api private
      def report_failure(error)
        return if @failure_reported

        @failure_reported = true
        Sentrifig.logger.error("[sentrifig] gate error, passing event through: #{error.class}: #{error.message}")
      rescue StandardError
        nil
      end
    end
  end
end
