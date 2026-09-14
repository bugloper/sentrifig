# frozen_string_literal: true

SeliseSentry::Engine.routes.draw do
  root to: "dashboard#show"

  post "enable",  to: "dashboard#enable",  as: :enable
  post "disable", to: "dashboard#disable", as: :disable
end
