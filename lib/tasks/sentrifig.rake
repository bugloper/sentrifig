# frozen_string_literal: true

# Resolves a scope from a Rake bracket argument, falling back to SCOPE= because
# bracket args need quoting under zsh, then to the backend switch.
def sentrifig_scope(value)
  Sentrifig::Scope.coerce(
    (value.nil? || value.to_s.empty? ? nil : value) ||
      (ENV["SCOPE"].nil? || ENV["SCOPE"].empty? ? nil : ENV["SCOPE"]) ||
      Sentrifig::Scope::BACKEND
  )
rescue ArgumentError => e
  abort("sentrifig: #{e.message}")
end

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

        4. To let browser clients read the frontend switch from
           GET <mount>/state, add your application's own authentication check:

             config.client_authenticator = ->(request) { MyAuth.user_from(request).present? }

           Until it is set, that endpoint refuses every request with 401. The
           Basic-auth dashboard is unaffected.

      Upgrading from 0.1.0? `sentrifig:install` copies by filename and will NOT
      replace a migration you already have. Delete
      db/migrate/*_create_sentrifig_settings.sentrifig.rb (rolling it back
      first), then re-run this task, or you will silently keep the old schema.

      Sentry stays ENABLED until you turn it off from /sentrifig or with
      `bin/rails sentrifig:disable`.
    STEPS
  end

  desc "Show whether Sentry is enabled for the current environment (both scopes)"
  task status: :environment do
    statuses = Sentrifig.statuses
    puts "Environment: #{statuses.first.environment}"

    statuses.each do |status|
      note =
        if status.persisted?
          "changed by #{status.changed_by || 'unknown'} at #{status.changed_at}"
        elsif status.degraded?
          "database unreachable, showing fallback state"
        else
          "no stored setting yet, showing default"
        end

      puts format("%-9s Sentry: %-8s (%s)", status.scope.capitalize, status.label, note)
    end

    sdk = statuses.first
    puts "SDK: #{sdk.sdk_ready? ? 'ready to send' : "not sending (#{Array(sdk.sdk_problems).join('; ')})"}"
  end

  desc "Enable Sentry for the current environment (scope: backend [default] or frontend)"
  task :enable, [:scope] => :environment do |_task, args|
    scope = sentrifig_scope(args[:scope])
    Sentrifig.enable!(by: "rake", scope: scope)
    puts "Environment: #{Sentrifig.current_environment}"
    puts "#{scope.capitalize} Sentry: ENABLED"
  end

  desc "Disable Sentry for the current environment (scope: backend [default] or frontend)"
  task :disable, [:scope] => :environment do |_task, args|
    scope = sentrifig_scope(args[:scope])
    Sentrifig.disable!(by: "rake", scope: scope)
    puts "Environment: #{Sentrifig.current_environment}"
    puts "#{scope.capitalize} Sentry: DISABLED"
  end

  desc "List the runtime settings for a scope (backend [default] or frontend), with their origin"
  task :settings, [:scope] => :environment do |_task, args|
    scope = sentrifig_scope(args[:scope])
    status = Sentrifig.status(scope)

    puts "Environment: #{status.environment}"
    puts "Scope: #{scope}"
    puts ""

    Sentrifig::Settings::Schema.for_scope(scope).each do |definition|
      value = status.settings[definition.key]
      origin =
        if status.overridden?(definition.key)
          "set here"
        elsif definition.env_present?
          "default from #{definition.env}"
        else
          "default"
        end

      puts format("  %-28s %-34s %s", definition.key, definition.to_form(value).inspect, "(#{origin})")
      puts format("  %-28s %s", "", definition.note) if definition.note
    end

    puts ""
    puts "Change one with: bin/rails \"sentrifig:set[#{scope},<key>,<value>]\""
    puts "Reset one with:  bin/rails \"sentrifig:reset[#{scope},<key>]\""
  end

  desc "Set one runtime setting: sentrifig:set[scope,key,value]"
  task :set, %i[scope key value] => :environment do |_task, args|
    scope = sentrifig_scope(args[:scope])
    abort("sentrifig: a key is required, e.g. sentrifig:set[#{scope},sample_rate,0.5]") if args[:key].to_s.empty?

    begin
      Sentrifig.update_settings!(scope, { args[:key].to_sym => args[:value] }, by: "rake")
    rescue Sentrifig::ValidationError => e
      abort("sentrifig: #{e.message}")
    end

    puts "#{scope} #{args[:key]} = #{Sentrifig.settings(scope)[args[:key].to_sym].inspect}"
  end

  desc "Reset one runtime setting to its default: sentrifig:reset[scope,key]"
  task :reset, %i[scope key] => :environment do |_task, args|
    scope = sentrifig_scope(args[:scope])
    abort("sentrifig: a key is required, e.g. sentrifig:reset[#{scope},sample_rate]") if args[:key].to_s.empty?

    begin
      Sentrifig.reset_setting!(scope, args[:key], by: "rake")
    rescue Sentrifig::ValidationError => e
      abort("sentrifig: #{e.message}")
    end

    puts "#{scope} #{args[:key]} reset to #{Sentrifig.settings(scope)[args[:key].to_sym].inspect}"
  end

  desc "Capture a test event and report whether the runtime switch and the Sentry SDK let it through"
  task test_event: :environment do
    status = Sentrifig.status
    frontend = Sentrifig.status(Sentrifig::Scope::FRONTEND)
    puts "Environment: #{status.environment}"
    puts "Backend Sentry switch: #{status.label}"
    puts "Frontend switch: #{frontend.label} (browser only; does not affect Ruby events)"

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
