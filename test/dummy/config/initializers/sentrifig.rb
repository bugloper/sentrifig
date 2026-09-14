# frozen_string_literal: true

Sentrifig.configure do |config|
  # SENTRIFIG_USERNAME / SENTRIFIG_PASSWORD are read by default; these
  # fallbacks only make the demo app usable without setting them.
  config.username ||= "admin"
  config.password ||= "secret"
  config.cache_ttl = Rails.env.test? ? 0 : 5

  # Browser clients: a real app checks its own session or token here. The demo
  # accepts any request outside the test environment so `GET /sentrifig/state`
  # can be tried with curl; the test suite leaves it unset on purpose, so tests
  # see the fail-closed path a host gets when it forgets this.
  config.client_authenticator = ->(_request) { true } unless Rails.env.test?

  # The gem calls Sentry.init with the Selise defaults (Sentrifig::SentrySetup).
  # The demo app records events in-process (DummyTransport) unless SENTRY_DSN is set.
  config.sentry do |sentry|
    sentry.dsn = ENV.fetch("SENTRY_DSN", "http://12345:67890@sentry.localdomain/sentry/42")
    sentry.enabled_environments = %w[development test]
    sentry.traces_sampler = nil
    sentry.traces_sample_rate = 1.0
    sentry.background_worker_threads = 0
    sentry.transport.transport_class = Sentry::DummyTransport unless ENV["SENTRY_DSN"]
    sentry.rails.register_error_subscriber = true
  end
end
