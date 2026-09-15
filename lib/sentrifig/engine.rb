# frozen_string_literal: true

require "rails/engine"

module Sentrifig
  class Engine < ::Rails::Engine
    isolate_namespace Sentrifig

    # Sentry.init with the Selise defaults plus the application's overrides.
    # `after: :load_config_initializers` orders this after every railtie's
    # config/initializers, including the application's, so overrides registered
    # there are known. It still runs before after_initialize, where sentry-rails
    # wires its integrations and requires Sentry to be initialised.
    initializer "sentrifig.init_sentry", after: :load_config_initializers do
      Sentrifig::SentrySetup.init! if Sentrifig.configuration.initialize_sentry
    end

    # Install the Sentry gate once the application (and its Sentry.init
    # initializer) has finished booting. The hook is registered on
    # Sentry::Scope, so ordering relative to Sentry.init is not critical; this
    # simply keeps the install visible in boot order.
    config.after_initialize do
      Sentrifig.install!
      # Stored overrides beat the environment variables SentrySetup just applied,
      # so re-assert them once the SDK exists. Best effort: a database that is
      # not reachable at boot leaves the env-derived values in place, and the
      # next settings change applies them.
      Sentrifig.apply_to_sentry!
    end
  end
end
