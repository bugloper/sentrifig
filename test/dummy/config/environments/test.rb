# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = false
  config.consider_all_requests_local = true
  # Render exceptions as 500 pages so sentry-rails' middleware sees them the
  # same way it does in production (report_rescued_exceptions is true there).
  config.action_dispatch.show_exceptions = :all
  config.action_controller.perform_caching = false
  config.action_controller.allow_forgery_protection = false
  config.cache_store = :null_store
  config.active_support.deprecation = :stderr
end

# The schema comes from the gem's own db/migrate (see test/test_helper.rb).
Rails.application.config.active_record.maintain_test_schema = false
