# frozen_string_literal: true

namespace :sentrifig do
  desc "Install sentrifig: copy its migration into db/migrate and print the remaining steps"
  task install: :environment do
    require "active_record"

    destination = ActiveRecord::Tasks::DatabaseTasks.migrations_paths.first
    source = Sentrifig::Engine.paths["db/migrate"].expanded.first

    puts "Installing sentrifig migration into #{destination}"
    copied = ActiveRecord::Migration.copy(
      destination,
      { sentrifig: source },
      on_copy: ->(_scope, migration, _old) { puts "  copied  #{File.basename(migration.filename)}" }
    )

    ActiveRecord::MigrationContext.new(source).migrations.each do |migration|
      next if copied.any? { |m| m.name == migration.name }

      puts "  skipped #{migration.name.underscore} (already present)"
    end

    puts <<~STEPS

      Next steps:

        1. Run the migration:

             bin/rails db:migrate

        2. Mount the UI in config/routes.rb:

             mount Sentrifig::Engine => "/sentrifig"

        3. Configure Basic Auth credentials (never commit them), e.g. in
           config/initializers/sentrifig.rb:

             Sentrifig.configure do |config|
               config.username = ENV.fetch("SENTRIFIG_USERNAME")
               config.password = ENV.fetch("SENTRIFIG_PASSWORD")
             end

      Sentry stays ENABLED until you turn it off from /sentrifig or with
      `bin/rails sentrifig:disable`.
    STEPS
  end

  desc "Show whether Sentry is enabled for the current environment"
  task status: :environment do
    status = Sentrifig.status
    puts "Environment: #{status.environment}"
    puts "Sentry: #{status.label}"
    puts "SDK: #{status.sdk_ready? ? 'ready to send' : "not sending (#{Array(status.sdk_problems).join('; ')})"}"
    if status.persisted?
      puts "Changed by: #{status.changed_by || 'unknown'} at #{status.changed_at}"
    elsif status.degraded?
      puts "Note: database unreachable, showing fallback state"
    else
      puts "Note: no stored setting yet, showing default"
    end
  end

  desc "Enable Sentry for the current environment"
  task enable: :environment do
    Sentrifig.enable!(by: "rake")
    puts "Environment: #{Sentrifig.current_environment}"
    puts "Sentry: ENABLED"
  end

  desc "Disable Sentry for the current environment"
  task disable: :environment do
    Sentrifig.disable!(by: "rake")
    puts "Environment: #{Sentrifig.current_environment}"
    puts "Sentry: DISABLED"
  end

  desc "Capture a test event and report whether the runtime switch and the Sentry SDK let it through"
  task test_event: :environment do
    status = Sentrifig.status
    puts "Environment: #{status.environment}"
    puts "Sentry switch: #{status.label}"

    unless status.sdk_ready?
      puts "Sentry SDK cannot send from this process: #{Array(status.sdk_problems).join('; ')}"
      puts "Set SENTRY_ENABLED=true and SENTRY_DSN, and make sure RUNTIME_ENVIRONMENT is one of " \
           "#{Array(Sentry.configuration.enabled_environments).join('/')}."
      exit 1
    end

    event = Sentry.capture_message("sentrifig test event", level: :info, tags: { source: "rake sentrifig:test_event" })
    Sentry.get_current_client&.flush

    if event
      puts "Event #{event.event_id} accepted by the SDK and handed to the transport. It should appear in Sentry shortly."
    elsif status.enabled?
      puts "Event dropped by the Sentry SDK itself (sampling, excluded exception or before_send), not by sentrifig."
    else
      puts "Event dropped by sentrifig: Sentry is DISABLED for #{status.environment}."
      exit 2
    end
  end
end
