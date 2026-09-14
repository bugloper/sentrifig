# frozen_string_literal: true

module SeliseSentry
  # Data-plane state holder. Owns the single in-memory copy of "is Sentry
  # enabled for this environment" that the Sentry gate consults on every event.
  #
  # Hot path (#enabled?): one instance-variable read plus a monotonic clock
  # comparison. At most once per cache_ttl seconds (per process) a single
  # thread re-reads the database; concurrent callers keep using the cached
  # value in the meantime rather than queueing behind the lock.
  #
  # Control plane (#update!, #refresh!, #status): synchronous, may hit the
  # database, and raise PersistenceError (update!) when the write fails.
  #
  # Failure model: if the database cannot be read, the last known state stays
  # in effect (or the configured default if nothing was ever loaded), the
  # failure is logged once, and the next attempt is deferred by cache_ttl.
  class Runtime
    Snapshot = Struct.new(:enabled, :source, :changed_by, :changed_at, keyword_init: true)

    Status = Struct.new(:enabled, :environment, :source, :changed_by, :changed_at, :cache_ttl,
                        :sdk_ready, :sdk_problems, keyword_init: true) do
      def enabled? = enabled == true
      # True when Sentry's own configuration allows sending (valid DSN, enabled environment).
      def sdk_ready? = sdk_ready == true
      def label = enabled? ? "ENABLED" : "DISABLED"
      # True when the value comes from a persisted row rather than the default.
      def persisted? = source == :database
      # True when the last database read failed and this is a fallback value.
      def degraded? = source == :fallback
    end

    MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    def initialize(configuration:, store: Store.new, clock: MONOTONIC_CLOCK)
      @configuration = configuration
      @store = store
      @clock = clock
      @lock = Mutex.new
      @snapshot = nil
      @next_refresh_at = 0.0
      @failing = false
    end

    # --- hot path ---------------------------------------------------------

    def enabled?
      snapshot = @snapshot
      snapshot = refresh_if_idle || snapshot if snapshot.nil? || @clock.call >= @next_refresh_at
      (snapshot || default_snapshot(:default)).enabled
    end

    # --- control plane ----------------------------------------------------

    # Persists the new state, applies it to this process immediately, logs.
    # @raise [PersistenceError]
    def update!(enabled, by: nil)
      record = @store.write(environment, enabled: enabled, changed_by: by)
      @lock.synchronize do
        @failing = false
        install_snapshot(snapshot_from(record))
      end
      log(:info, "Sentry #{word(enabled)} environment=#{environment} by=#{by || 'unknown'}")
      enabled
    rescue StandardError => e
      log(:error, "could not persist Sentry #{word(enabled)} for environment=#{environment}: #{e.class}: #{e.message}")
      raise PersistenceError, "could not persist selise-sentry state: #{e.class}: #{e.message}"
    end

    # Forces a synchronous database read (best effort: falls back like the hot
    # path does when the database is unavailable).
    def refresh!
      @lock.synchronize { load_from_store }
    end

    # Fresh view for UIs/CLIs. Reads the database best-effort first.
    def status
      snapshot = refresh!
      Status.new(
        enabled: snapshot.enabled,
        environment: environment,
        source: snapshot.source,
        changed_by: snapshot.changed_by,
        changed_at: snapshot.changed_at,
        cache_ttl: @configuration.cache_ttl
      )
    end

    # Drops the cached state. Intended for tests and for after re-configuration.
    def reset!
      @lock.synchronize do
        @snapshot = nil
        @next_refresh_at = 0.0
        @failing = false
      end
    end

    def environment = @configuration.environment

    private

    def refresh_if_idle
      return nil unless @lock.try_lock

      begin
        # Another thread may have refreshed while we were acquiring the lock.
        return @snapshot if @snapshot && @clock.call < @next_refresh_at

        load_from_store
      ensure
        @lock.unlock
      end
    end

    # Caller must hold @lock.
    def load_from_store
      record = @store.fetch(environment)
      fresh = record ? snapshot_from(record) : default_snapshot(:default)

      if @failing
        @failing = false
        log(:info, "database reachable again; Sentry #{word(fresh.enabled)} environment=#{environment}")
      elsif @snapshot && @snapshot.enabled != fresh.enabled
        log(:info, "Sentry #{word(fresh.enabled)} (picked up from database) environment=#{environment} by=#{fresh.changed_by || 'unknown'}")
      end

      install_snapshot(fresh)
    rescue StandardError => e
      fallback = @snapshot || default_snapshot(:fallback)

      unless @failing
        @failing = true
        log(:warn, "could not read state (#{e.class}: #{e.message}); keeping Sentry #{word(fallback.enabled)} " \
                   "for environment=#{environment}, retrying in #{@configuration.cache_ttl}s")
      end

      install_snapshot(fallback)
    end

    # Caller must hold @lock.
    def install_snapshot(snapshot)
      @snapshot = snapshot
      @next_refresh_at = @clock.call + @configuration.cache_ttl
      snapshot
    end

    def snapshot_from(record)
      Snapshot.new(enabled: record.enabled == true, source: :database,
                   changed_by: record.changed_by, changed_at: record.updated_at).freeze
    end

    def default_snapshot(source)
      Snapshot.new(enabled: @configuration.enabled_by_default, source: source, changed_by: nil, changed_at: nil).freeze
    end

    def word(enabled) = enabled ? "enabled" : "disabled"

    def log(level, message)
      @configuration.logger.public_send(level, "[selise-sentry] #{message}")
    rescue StandardError
      nil
    end
  end
end
