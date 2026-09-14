# frozen_string_literal: true

require "test_helper"

module Sentrifig
  class PublicApiTest < ActiveSupport::TestCase
    test "initial state is enabled with no row in the database" do
      assert Sentrifig.enabled?
      assert_equal 0, Setting.count
      status = Sentrifig.status
      assert status.enabled?
      assert_equal "ENABLED", status.label
      assert_not status.persisted?
    end

    test "disable! and enable! persist and take effect immediately" do
      Sentrifig.disable!(by: "alice")
      assert_not Sentrifig.enabled?
      assert_equal "DISABLED", Sentrifig.status.label
      row = Setting.find_by!(environment: "test")
      assert_equal false, row.enabled
      assert_equal "alice", row.changed_by

      Sentrifig.enable!(by: "bob")
      assert Sentrifig.enabled?
      assert_equal "bob", row.reload.changed_by
      assert_equal 1, Setting.count
    end

    test "state survives a process restart (fresh runtime reads the database)" do
      Sentrifig.disable!
      Sentrifig.reset!
      configure_sentrifig
      assert_not Sentrifig.enabled?, "a new process must read the persisted state"
    end

    test "environments are isolated" do
      configure_sentrifig(environment: "production")
      Sentrifig.disable!
      assert_not Sentrifig.enabled?

      configure_sentrifig(environment: "test")
      assert Sentrifig.enabled?

      assert_equal %w[production], Setting.where(enabled: false).pluck(:environment)
    end

    test "current_environment defaults to Rails.env" do
      assert_equal "test", Sentrifig.current_environment
      configure_sentrifig(environment: "staging")
      assert_equal "staging", Sentrifig.current_environment
    end

    test "refresh! picks up a change made outside the runtime" do
      configure_sentrifig(cache_ttl: 300)
      assert Sentrifig.enabled?
      Setting.create!(environment: "test", scope: Scope::BACKEND, enabled: false, changed_by: "other-process")
      assert Sentrifig.enabled?, "cached"
      assert_equal false, Sentrifig.refresh!
      assert_not Sentrifig.enabled?
    end

    test "logs every change once" do
      logger, log = capturing_logger
      configure_sentrifig(logger: logger)
      Sentrifig.disable!(by: "alice")
      Sentrifig.enable!(by: "alice")
      assert_equal ["[sentrifig] Sentry disabled scope=backend environment=test by=alice",
                    "[sentrifig] Sentry enabled scope=backend environment=test by=alice"], log.string.lines.map(&:chomp)
    end

    test "hot path does not log" do
      logger, log = capturing_logger
      configure_sentrifig(logger: logger)
      100.times { Sentrifig.enabled? }
      assert_empty log.string
    end

    # --- scopes -------------------------------------------------------------

    test "enabled? stays backend-only, whatever the frontend switch says" do
      Sentrifig.disable!(by: "alice", scope: Scope::FRONTEND)

      assert Sentrifig.enabled?
      assert_not Sentrifig.enabled_for?(Scope::FRONTEND)
      assert Sentrifig.enabled_for?(Scope::BACKEND)
    end

    test "the scopes are stored as separate rows" do
      Sentrifig.disable!(by: "alice")
      Sentrifig.enable!(by: "bob", scope: Scope::FRONTEND)

      assert_equal 2, Setting.count
      assert_equal "alice", Setting.find_by!(environment: "test", scope: Scope::BACKEND).changed_by
      assert_equal "bob", Setting.find_by!(environment: "test", scope: Scope::FRONTEND).changed_by
    end

    test "statuses returns one status per scope, in order" do
      statuses = Sentrifig.statuses

      assert_equal Scope::ALL, statuses.map(&:scope)
      assert statuses.all?(&:sdk_ready?), "sdk readiness is merged into every scope"
    end

    test "status takes a scope" do
      Sentrifig.disable!(by: "alice", scope: Scope::FRONTEND)

      assert_equal "DISABLED", Sentrifig.status(Scope::FRONTEND).label
      assert_equal "ENABLED", Sentrifig.status.label
    end

    test "refresh! with no argument refreshes every scope" do
      configure_sentrifig(cache_ttl: 300)
      assert Sentrifig.enabled?
      assert Sentrifig.enabled_for?(Scope::FRONTEND)

      Setting.create!(environment: "test", scope: Scope::BACKEND, enabled: false, changed_by: "other")
      Setting.create!(environment: "test", scope: Scope::FRONTEND, enabled: false, changed_by: "other")
      assert Sentrifig.enabled?, "cached"

      Sentrifig.refresh!

      assert_not Sentrifig.enabled?
      assert_not Sentrifig.enabled_for?(Scope::FRONTEND)
    end

    test "an unknown scope raises rather than silently reading the backend" do
      ["Frontend", "", nil, "client"].each do |bad|
        assert_raises(ArgumentError) { Sentrifig.enabled_for?(bad) }
      end
    end

    test "configure rebuilds both runtimes" do
      Sentrifig.disable!(by: "alice", scope: Scope::FRONTEND)
      assert_not Sentrifig.enabled_for?(Scope::FRONTEND)

      configure_sentrifig(environment: "other-environment")

      assert Sentrifig.enabled_for?(Scope::FRONTEND), "a fresh environment has no stored row"
      assert_equal "other-environment", Sentrifig.status(Scope::FRONTEND).environment
    end
  end

  class ConcurrentUpdatesTest < ActiveSupport::TestCase
    # Threads need their own connections and must see each other's commits.
    self.use_transactional_tests = false

    teardown { Setting.delete_all }

    test "concurrent enable!/disable! from many threads leave one consistent row" do
      errors = Queue.new
      threads = 6.times.map do |i|
        Thread.new do
          20.times { |n| (i + n).even? ? Sentrifig.enable!(by: "t#{i}") : Sentrifig.disable!(by: "t#{i}") }
        rescue StandardError => e
          errors << e
        end
      end
      threads.each(&:join)

      assert_empty Array.new(errors.size) { errors.pop }
      assert_equal 1, Setting.where(environment: "test").count
      assert_equal Setting.find_by!(environment: "test").enabled, Sentrifig.refresh!
    end
  end
end
