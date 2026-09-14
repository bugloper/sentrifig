# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rails", "~> 8.1"

# Run the suite against another sentry release: SENTRY_VERSION=6.6.2 bundle install && bundle exec rake test
if ENV["SENTRY_VERSION"]
  gem "sentry-ruby", ENV["SENTRY_VERSION"]
  gem "sentry-rails", ENV["SENTRY_VERSION"]
end
gem "sqlite3", ">= 2.1"
gem "puma"
gem "minitest", "~> 5.25"
gem "rake"
# json 3.x changed JSON.parse's signature; Rails 8.1 message metadata still passes options.
gem "json", "< 3"
