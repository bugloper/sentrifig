# frozen_string_literal: true

Rails.application.routes.draw do
  mount SeliseSentry::Engine => "/selise-sentry"

  get "/ok",      to: "demo#ok"
  get "/capture", to: "demo#capture"
  get "/boom",   to: "demo#boom"
  get "/report", to: "demo#report"
  root to: "demo#ok"
end
