# frozen_string_literal: true

require "test_helper"

module Sentrifig
  class RuntimeTest < ActiveSupport::TestCase
    # In-memory stand-in for Store: lets tests simulate other processes
    # writing, database outages, and slow queries deterministically.
    class FakeStore
      attr_accessor :failure, :block_on_fetch
      attr_reader :fetches, :writes

      def initialize
        @rows = {}
        @fetches = 0
        @writes = 0
        @failure = nil
      end

      # Keyed by [environment, scope], like the real table's unique index.
      def set(environment, enabled:, scope: Scope::BACKEND, values: {}, changed_by: "other-process")
        @rows[[environment, scope]] =
          Store::Record.new(enabled: enabled, values: values, changed_by: changed_by, updated_at: Time.now)
      end

      def fetch(environment, scope: Scope::BACKEND)
        @fetches += 1
        @block_on_fetch&.call
        raise @failure if @failure

        @rows[[environment, scope]]
      end

      def write(environment, enabled: :unchanged, scope: Scope::BACKEND, values: :unchanged, changed_by: nil)
        @writes += 1
        raise @failure if @failure

        existing = @rows[[environment, scope]]
        set(environment,
            enabled: enabled == :unchanged ? existing&.enabled : enabled,
            scope: scope,
            values: values == :unchanged ? (existing&.values || {}) : values,
            changed_by: changed_by)
      end
    end

    class FakeClock
      attr_accessor :now

      def initialize = @now = 1000.0
      def call = @now
      def advance(seconds) = @now += seconds
    end

    setup do
      @logger, @log = capturing_logger
      @config = Configuration.new
      @config.cache_ttl = 5
      @config.environment = "production"
      @config.logger = @logger
      @store = FakeStore.new
      @clock = FakeClock.new
      @runtime = Runtime.new(configuration: @config, store: @store, clock: @clock)
    end

    test "no record means the default (enabled)" do
      assert @runtime.enabled?
      assert_equal :default, @runtime.status.source
    end

    test "enabled_by_default=false is honoured when no record exists" do
      @config.enabled_by_default = false
      assert_not @runtime.enabled?
    end

    test "update! persists and applies immediately" do
      assert_equal false, @runtime.update!(false, by: "alice")
      assert_not @runtime.enabled?
      assert_equal 1, @store.writes
      assert_equal false, @store.fetch("production").enabled
      assert_includes @log.string, "[sentrifig] Sentry disabled scope=backend environment=production by=alice"
    end

    test "the cached value is trusted until cache_ttl elapses" do
      assert @runtime.enabled?
      fetches_after_first = @store.fetches

      @store.set("production", enabled: false) # another process flipped it
      @clock.advance(4.9)
      assert @runtime.enabled?, "stale value should still be served inside the TTL"
      assert_equal fetches_after_first, @store.fetches, "no database read inside the TTL"

      @clock.advance(0.2)
      assert_not @runtime.enabled?, "fresh value after the TTL"
      assert_equal fetches_after_first + 1, @store.fetches
      assert_includes @log.string, "Sentry disabled (picked up from database) scope=backend environment=production by=other-process"
    end

    test "hot path reads do not touch the store inside the TTL" do
      @runtime.enabled?
      count = @store.fetches
      1_000.times { @runtime.enabled? }
      assert_equal count, @store.fetches
    end

    test "cache_ttl of 0 re-reads on every call" do
      @config.cache_ttl = 0
      @runtime.enabled?
      @runtime.enabled?
      @runtime.enabled?
      assert_equal 3, @store.fetches
    end

    test "refresh! bypasses the TTL" do
      assert @runtime.enabled?
      @store.set("production", enabled: false)
      @runtime.refresh!
      assert_not @runtime.enabled?
    end

    test "a store failure keeps the last known state and logs once" do
      @store.set("production", enabled: false)
      assert_not @runtime.enabled?

      @store.failure = ActiveRecord::ConnectionNotEstablished.new("db down")
      @clock.advance(6)
      assert_not @runtime.enabled?, "last known state (disabled) must survive the outage"
      @clock.advance(6)
      @clock.advance(6)
      @runtime.enabled?
      @runtime.enabled?

      warnings = @log.string.scan(/could not read state/)
      assert_equal 1, warnings.size, "outage must be logged once, not on every retry"
      assert_includes @log.string, "keeping Sentry disabled for scope=backend environment=production, retrying in 5s"
    end

    test "a store failure before anything was loaded falls back to the default" do
      @store.failure = ActiveRecord::StatementInvalid.new("no such table: sentrifig_settings")
      assert @runtime.enabled?
      status = @runtime.status
      assert status.degraded?
      assert_equal :fallback, status.source
    end

    test "failed refreshes back off for cache_ttl" do
      @store.failure = RuntimeError.new("boom")
      @runtime.enabled?
      count = @store.fetches
      100.times { @runtime.enabled? }
      assert_equal count, @store.fetches

      @clock.advance(5)
      @runtime.enabled?
      assert_equal count + 1, @store.fetches
    end

    test "recovery after an outage is logged and picks up the new state" do
      assert @runtime.enabled?
      @store.failure = RuntimeError.new("boom")
      @clock.advance(6)
      @runtime.enabled?

      @store.failure = nil
      @store.set("production", enabled: false)
      @clock.advance(6)
      assert_not @runtime.enabled?
      assert_includes @log.string, "database reachable again; Sentry disabled scope=backend environment=production"
    end

    test "update! failure raises PersistenceError and leaves the state alone" do
      assert @runtime.enabled?
      @store.failure = ActiveRecord::ConnectionNotEstablished.new("db down")

      error = assert_raises(PersistenceError) { @runtime.update!(false, by: "alice") }
      assert_match(/ConnectionNotEstablished/, error.message)
      assert @runtime.enabled?
      assert_includes @log.string, "could not persist Sentry disabled for scope=backend environment=production"
    end

    test "update! resets the failure state so recovery is not logged twice" do
      @store.failure = RuntimeError.new("boom")
      @runtime.enabled?
      @store.failure = nil
      @runtime.update!(false, by: "alice")
      @clock.advance(6)
      @runtime.enabled?
      assert_not_includes @log.string, "database reachable again"
    end

    test "status reflects the persisted record" do
      @store.set("production", enabled: false, changed_by: "alice")
      status = @runtime.status

      assert_equal false, status.enabled
      assert_equal "DISABLED", status.label
      assert_equal "production", status.environment
      assert status.persisted?
      assert_equal "alice", status.changed_by
      assert_kind_of Time, status.changed_at
      assert_equal 5, status.cache_ttl
    end

    test "concurrent readers never block behind a slow refresh" do
      release = Queue.new
      started = Queue.new
      @store.block_on_fetch = lambda do
        started << true
        release.pop
      end

      slow = Thread.new { @runtime.enabled? }
      started.pop # the slow thread now holds the lock inside the store

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      fast_result = @runtime.enabled?
      fast_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      assert_equal true, fast_result, "default served while another thread refreshes"
      assert_operator fast_duration, :<, 0.5

      release << true
      assert_equal true, slow.value
    end

    test "many threads toggling and reading stays consistent and never raises" do
      @config.cache_ttl = 0
      errors = Queue.new
      threads = 8.times.map do |i|
        Thread.new do
          50.times do |n|
            @runtime.update!((i + n).even?, by: "t#{i}")
            @runtime.enabled?
          end
        rescue StandardError => e
          errors << e
        end
      end
      threads.each(&:join)

      assert_empty errors.size.times.map { errors.pop }
      assert_equal @store.fetch("production").enabled, @runtime.enabled?
    end

    test "log failures never propagate" do
      @config.logger = Object.new # responds to nothing
      @store.set("production", enabled: false)
      assert_nothing_raised { @runtime.update!(true, by: "x") }
    end

    test "each scope refreshes independently over the same store" do
      frontend = Runtime.new(configuration: @config, scope: Scope::FRONTEND, store: @store, clock: @clock)

      @store.set("production", scope: Scope::BACKEND, enabled: false)
      @store.set("production", scope: Scope::FRONTEND, enabled: true)

      assert_not @runtime.enabled?
      assert frontend.enabled?
      assert_equal Scope::FRONTEND, frontend.scope
      assert_equal Scope::FRONTEND, frontend.status.scope
    end

    test "a frontend outage does not put the backend runtime into the failing state" do
      frontend = Runtime.new(configuration: @config, scope: Scope::FRONTEND, store: @store, clock: @clock)

      assert @runtime.enabled?, "backend reads cleanly first"

      @store.failure = ActiveRecord::ConnectionNotEstablished.new("db down")
      @clock.advance(10)
      frontend.enabled?

      @store.failure = nil
      @store.set("production", scope: Scope::BACKEND, enabled: false)
      @clock.advance(10)

      assert_not @runtime.enabled?
      assert_not_includes @log.string, "database reachable again; Sentry disabled scope=backend"
    end

    test "an unknown scope is refused at construction" do
      assert_raises(ArgumentError) { Runtime.new(configuration: @config, scope: "sideways", store: @store) }
    end
  end
end
