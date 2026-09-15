# frozen_string_literal: true

Sentrifig::Engine.routes.draw do
  root to: "dashboard#show"

  # Read-only state for browser clients. Authenticated by the host application
  # through config.client_authenticator, never by the operator Basic
  # credentials. One representation, so no format segment and no respond_to.
  get "state", to: "state#show", as: :state

  scope ":scope", constraints: { scope: Regexp.union(Sentrifig::Scope::ALL) } do
    post "enable",  to: "dashboard#enable",  as: :scoped_enable
    post "disable", to: "dashboard#disable", as: :scoped_disable

    # Runtime settings. POST-only and CSRF-protected like the switches.
    post "settings",           to: "settings#update", as: :scoped_settings
    post "settings/:key/reset", to: "settings#reset", as: :scoped_setting_reset
  end

  # Pre-0.2 paths, kept: they act on the backend switch.
  post "enable",  to: "dashboard#enable",  as: :enable,  defaults: { scope: Sentrifig::Scope::BACKEND }
  post "disable", to: "dashboard#disable", as: :disable, defaults: { scope: Sentrifig::Scope::BACKEND }
end
