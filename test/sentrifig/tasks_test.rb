# frozen_string_literal: true

require "test_helper"
require "rake"

module Sentrifig
  class TasksTest < ActiveSupport::TestCase
    setup do
      Rake.application = Rake::Application.new
      Rake::Task.define_task(:environment)
      load File.expand_path("../../lib/tasks/sentrifig.rake", __dir__)
    end

    # Captures stderr as well as stdout: `abort` writes its message to stderr.
    def run_task(name, *args)
      out = StringIO.new
      err = StringIO.new
      $stdout = out
      $stderr = err
      Rake::Task[name].reenable
      Rake::Task[name].invoke(*args)
      out.string + err.string
    rescue SystemExit => e
      out.string + err.string + "[exit #{e.status}]"
    ensure
      $stdout = STDOUT
      $stderr = STDERR
    end

    test "status shows the default state and SDK readiness" do
      output = run_task("sentrifig:status")
      assert_includes output, "Environment: test"
      assert_includes output, "Sentry: ENABLED"
      assert_includes output, "SDK: ready to send"
      assert_includes output, "no stored setting yet"
    end

    test "status explains when the SDK cannot send" do
      Sentry.configuration.dsn = nil
      output = run_task("sentrifig:status")
      assert_includes output, "SDK: not sending (DSN not set or not valid)"
    end

    test "test_event reports an accepted event while enabled" do
      output = run_task("sentrifig:test_event")
      assert_includes output, "Sentry switch: ENABLED"
      assert_match(/Event \h{32} accepted by the SDK/, output)
      assert_equal ["sentrifig test event"], sentry_events.map(&:message)
    end

    test "test_event reports the drop while disabled and exits 2" do
      Sentrifig.disable!(by: "spec")
      output = run_task("sentrifig:test_event")
      assert_includes output, "Sentry switch: DISABLED"
      assert_includes output, "dropped by sentrifig"
      assert_includes output, "[exit 2]"
      assert_empty sentry_events
    end

    test "test_event explains when the SDK itself cannot send and exits 1" do
      Sentry.configuration.dsn = nil
      output = run_task("sentrifig:test_event")
      assert_includes output, "cannot send from this process: DSN not set or not valid"
      assert_includes output, "[exit 1]"
    end

    test "disable and enable share the state with the API and UI" do
      output = run_task("sentrifig:disable")
      assert_includes output, "Sentry: DISABLED"
      assert_not Sentrifig.enabled?
      assert_equal "rake", Setting.find_by!(environment: "test", scope: Scope::BACKEND).changed_by

      output = run_task("sentrifig:status")
      assert_includes output, "Sentry: DISABLED"
      assert_match(/Backend\s+Sentry: DISABLED \(changed by rake/, output)

      run_task("sentrifig:enable")
      assert Sentrifig.enabled?
    end

    test "install copies the migration into the application and prints next steps" do
      Dir.mktmpdir do |dir|
        ActiveRecord::Tasks::DatabaseTasks.stub(:migrations_paths, [dir]) do
          output = run_task("sentrifig:install")
          assert_includes output, "copied"
          assert_includes output, "bin/rails db:migrate"
          assert_includes output, 'mount Sentrifig::Engine => "/sentrifig"'
          assert_includes output, "SENTRIFIG_USERNAME"

          copied = Dir[File.join(dir, "*_create_sentrifig_settings.sentrifig.rb")]
          assert_equal 1, copied.size
          assert_includes File.read(copied.first), "create_table :sentrifig_settings"

          output = run_task("sentrifig:install")
          assert_includes output, "skipped"
          assert_equal 1, Dir[File.join(dir, "*.rb")].size, "installer must be idempotent"
        end
      end
    end

    test "status prints both scopes" do
      Sentrifig.disable!(by: "rake", scope: Scope::FRONTEND)

      output = run_task("sentrifig:status")

      assert_match(/Backend\s+Sentry: ENABLED/, output)
      assert_match(/Frontend\s+Sentry: DISABLED \(changed by rake/, output)
    end

    test "enable and disable take a scope argument, defaulting to backend" do
      run_task("sentrifig:disable", "frontend")

      assert Sentrifig.enabled?, "the backend switch must be untouched"
      assert_not Sentrifig.enabled_for?(Scope::FRONTEND)

      run_task("sentrifig:enable", "frontend")
      assert Sentrifig.enabled_for?(Scope::FRONTEND)
    end

    test "SCOPE= is honoured when no bracket argument is given" do
      with_env("SCOPE" => "frontend") do
        run_task("sentrifig:disable")
      end

      assert Sentrifig.enabled?
      assert_not Sentrifig.enabled_for?(Scope::FRONTEND)
    end

    test "an unknown scope aborts rather than writing a bogus row" do
      output = run_task("sentrifig:disable", "sideways")

      assert_includes output, "unknown sentrifig scope"
      assert Sentrifig.enabled?
      assert_equal 0, Setting.count
    end
  end
end
