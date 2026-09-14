# frozen_string_literal: true

require "test_helper"

module SeliseSentry
  class PublicApiTest < ActiveSupport::TestCase
    test "initial state is enabled with no row in the database" do
      assert SeliseSentry.enabled?
      assert_equal 0, Setting.count
      status = SeliseSentry.status
      assert status.enabled?
      assert_equal "ENABLED", status.label
      assert_not status.persisted?
    end

    test "disable! and enable! persist and take effect immediately" do
      SeliseSentry.disable!(by: "alice")
      assert_not SeliseSentry.enabled?
      assert_equal "DISABLED", SeliseSentry.status.label
      row = Setting.find_by!(environment: "test")
      assert_equal false, row.enabled
      assert_equal "alice", row.changed_by

      SeliseSentry.enable!(by: "bob")
      assert SeliseSentry.enabled?
      assert_equal "bob", row.reload.changed_by
      assert_equal 1, Setting.count
    end

    test "state survives a process restart (fresh runtime reads the database)" do
      SeliseSentry.disable!
      SeliseSentry.reset!
      configure_selise_sentry
      assert_not SeliseSentry.enabled?, "a new process must read the persisted state"
    end

    test "environments are isolated" do
      configure_selise_sentry(environment: "production")
      SeliseSentry.disable!
      assert_not SeliseSentry.enabled?

      configure_selise_sentry(environment: "test")
      assert SeliseSentry.enabled?

      assert_equal %w[production], Setting.where(enabled: false).pluck(:environment)
    end

    test "current_environment defaults to Rails.env" do
      assert_equal "test", SeliseSentry.current_environment
      configure_selise_sentry(environment: "staging")
      assert_equal "staging", SeliseSentry.current_environment
    end

    test "refresh! picks up a change made outside the runtime" do
      configure_selise_sentry(cache_ttl: 300)
      assert SeliseSentry.enabled?
      Setting.create!(environment: "test", enabled: false, changed_by: "other-process")
      assert SeliseSentry.enabled?, "cached"
      assert_equal false, SeliseSentry.refresh!
      assert_not SeliseSentry.enabled?
    end

    test "logs every change once" do
      logger, log = capturing_logger
      configure_selise_sentry(logger: logger)
      SeliseSentry.disable!(by: "alice")
      SeliseSentry.enable!(by: "alice")
      assert_equal ["[selise-sentry] Sentry disabled environment=test by=alice",
                    "[selise-sentry] Sentry enabled environment=test by=alice"], log.string.lines.map(&:chomp)
    end

    test "hot path does not log" do
      logger, log = capturing_logger
      configure_selise_sentry(logger: logger)
      100.times { SeliseSentry.enabled? }
      assert_empty log.string
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
          20.times { |n| (i + n).even? ? SeliseSentry.enable!(by: "t#{i}") : SeliseSentry.disable!(by: "t#{i}") }
        rescue StandardError => e
          errors << e
        end
      end
      threads.each(&:join)

      assert_empty Array.new(errors.size) { errors.pop }
      assert_equal 1, Setting.where(environment: "test").count
      assert_equal Setting.find_by!(environment: "test").enabled, SeliseSentry.refresh!
    end
  end
end
