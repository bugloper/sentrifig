# frozen_string_literal: true

module Sentrifig
  # Data-plane state holder. Owns the single in-memory copy of "is Sentry
  # enabled for this environment and scope" that the Sentry gate consults on
  # every event.
  #
  # One instance per scope, not one instance holding a per-scope map: the hot
  # path below is one ivar read and one clock comparison, and a map would turn
  # every one of @snapshot/@next_refresh_at/@lock into a hash lookup. It would
  # also force a choice between one mutex serialising both scopes' database
  # reads -- where a frontend refresh blocks a backend refresh's try_lock and
  # the backend silently serves stale state -- and a hash of mutexes.
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
    Snapshot = Struct.new(:enabled, :values, :source, :changed_by, :changed_at, keyword_init: true) do
      # Stored overrides only. Resolution against the schema happens in
      # #settings, so a snapshot stays a faithful copy of the row.
      def values = (self[:values] || {})
    end

    Status = Struct.new(:enabled, :environment, :scope, :source, :changed_by, :changed_at, :cache_ttl,
                        :settings, :overridden, :sdk_ready, :sdk_problems, keyword_init: true) do
      def enabled? = enabled == true
      # True when Sentry's own configuration allows sending (valid DSN, enabled environment).
      def sdk_ready? = sdk_ready == true
      def label = enabled? ? "ENABLED" : "DISABLED"
      # True when the value comes from a persisted row rather than the default.
      def persisted? = source == :database
      # True when the last database read failed and this is a fallback value.
      def degraded? = source == :fallback
      # True when this setting is an operator override rather than a default.
      def overridden?(key) = Array(overridden).include?(key.to_sym)
    end

    MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    attr_reader :scope

    def initialize(configuration:, scope: Scope::BACKEND, store: Store.new, clock: MONOTONIC_CLOCK)
      @configuration = configuration
      @scope = Scope.coerce(scope)
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
      record = persist(enabled: enabled, by: by, failure: "Sentry #{word(enabled)}") do
        log(:info, "Sentry #{word(enabled)} scope=#{@scope} environment=#{environment} by=#{by || 'unknown'}")
      end
      record.enabled
    end

    # Merges setting overrides into the stored row. Keys mapped to nil are
    # removed, which is how "reset to default" is expressed.
    #
    # @param changes [Hash{Symbol=>Object}] already cast by the schema
    # @raise [PersistenceError]
    def update_settings!(changes, by: nil)
      merged = current_values.merge(changes).reject { |_key, value| value.nil? }

      persist(values: merged, by: by, failure: "settings") do
        described = changes.map { |key, value| "#{key}=#{value.nil? ? '(default)' : value.inspect}" }
        log(:info, "settings changed scope=#{@scope} environment=#{environment} " \
                   "by=#{by || 'unknown'} #{described.join(' ')}")
      end

      settings
    end

    # Resolved values for every setting in the scope: a stored override if there
    # is one, otherwise the environment variable, otherwise the schema default.
    def settings
      stored = current_values
      defaults = @scope == Scope::BACKEND ? Sentrifig.baseline : {}

      Settings::Schema.for_scope(@scope).to_h do |definition|
        key = definition.key
        [key, stored.fetch(key) { defaults.fetch(key) { definition.default_value } }]
      end
    end

    # Which settings are operator overrides rather than defaults.
    def overridden_keys
      schema_keys = Settings::Schema.keys(@scope)
      current_values.keys.select { |key| schema_keys.include?(key) }
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
        scope: @scope,
        source: snapshot.source,
        changed_by: snapshot.changed_by,
        changed_at: snapshot.changed_at,
        cache_ttl: @configuration.cache_ttl,
        settings: settings,
        overridden: overridden_keys
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
      record = @store.fetch(environment, scope: @scope)
      fresh = record ? snapshot_from(record) : default_snapshot(:default)

      if @failing
        @failing = false
        log(:info, "database reachable again; Sentry #{word(fresh.enabled)} scope=#{@scope} environment=#{environment}")
      elsif @snapshot && @snapshot.enabled != fresh.enabled
        log(:info, "Sentry #{word(fresh.enabled)} (picked up from database) scope=#{@scope} " \
                   "environment=#{environment} by=#{fresh.changed_by || 'unknown'}")
      end

      install_snapshot(fresh)
    rescue StandardError => e
      fallback = @snapshot || default_snapshot(:fallback)

      unless @failing
        @failing = true
        log(:warn, "could not read state (#{e.class}: #{e.message}); keeping Sentry #{word(fallback.enabled)} " \
                   "for scope=#{@scope} environment=#{environment}, retrying in #{@configuration.cache_ttl}s")
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
      Snapshot.new(enabled: record.enabled == true, values: record.values.freeze, source: :database,
                   changed_by: record.changed_by, changed_at: record.updated_at).freeze
    end

    def default_snapshot(source)
      Snapshot.new(enabled: @configuration.enabled_by_default, values: {}.freeze, source: source,
                   changed_by: nil, changed_at: nil).freeze
    end

    # Reads through the cache like the hot path does, so callers see the same
    # value the gate would.
    def current_values
      enabled?
      (@snapshot || default_snapshot(:default)).values
    end

    # Shared write path for the switch and for settings.
    def persist(by:, failure:, enabled: :unchanged, values: :unchanged)
      record = @store.write(environment, scope: @scope, enabled: enabled, values: values, changed_by: by)
      @lock.synchronize do
        @failing = false
        install_snapshot(snapshot_from(record))
      end
      yield
      record
    rescue StandardError => e
      log(:error, "could not persist #{failure} for scope=#{@scope} environment=#{environment}: " \
                  "#{e.class}: #{e.message}")
      raise PersistenceError, "could not persist sentrifig state: #{e.class}: #{e.message}"
    end

    def word(enabled) = enabled ? "enabled" : "disabled"

    def log(level, message)
      @configuration.logger.public_send(level, "[sentrifig] #{message}")
    rescue StandardError
      nil
    end
  end
end
