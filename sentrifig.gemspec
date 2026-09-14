# frozen_string_literal: true

require_relative "lib/sentrifig/version"

Gem::Specification.new do |spec|
  spec.name        = "sentrifig"
  spec.version     = Sentrifig::VERSION
  spec.authors     = ["SELISE"]
  spec.summary     = "Runtime on/off switch for Sentry in Rails, with a mountable Basic-Auth protected UI."
  spec.description = <<~DESC
    sentrifig lets operators enable or disable Sentry error reporting for a Rails
    application at runtime, per environment, without a deploy, restart, or environment
    variable change. State lives in the application's own database, is cached in memory
    on the Sentry hot path, and is controlled through a small mountable Rails Engine UI
    protected by HTTP Basic Authentication, or through rake tasks.
  DESC
  spec.homepage    = "https://github.com/bugloper/sentrifig"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "{app,config,db,lib}/**/*",
    "docs/**/*",
    "CHANGELOG.md",
    "LICENSE.txt",
    "README.md"
  ]

  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "actionpack", ">= 7.1"
  spec.add_dependency "sentry-ruby", ">= 5.12", "< 8"
  spec.add_dependency "sentry-rails", ">= 5.12", "< 8"
end
