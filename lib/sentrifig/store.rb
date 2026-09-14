# frozen_string_literal: true

module Sentrifig
  # Control-plane persistence. Talks to the sentrifig_settings table through
  # the Sentrifig::Setting ActiveRecord model and knows nothing about caching.
  #
  # Every method here may raise ActiveRecord errors; Runtime decides how to
  # degrade. This class is never on the Sentry hot path directly.
  class Store
    Record = Struct.new(:enabled, :changed_by, :updated_at, keyword_init: true) do
      def enabled? = enabled == true
    end

    # @return [Record, nil] nil when no row exists for the environment and scope
    def fetch(environment, scope: Scope::BACKEND)
      with_connection do
        row = Setting.where(environment: environment, scope: scope).first
        row && Record.new(enabled: row.enabled, changed_by: row.changed_by, updated_at: row.updated_at)
      end
    end

    # Upserts the single row for +environment+ and +scope+. Safe under
    # concurrent writers: the unique index on (environment, scope) makes a
    # racing insert fail with RecordNotUnique, in which case we reload and
    # update the winner's row. Concurrent updates to the existing row are
    # last-write-wins, which is the desired semantics for an operator kill
    # switch.
    #
    # @return [Record]
    def write(environment, enabled:, scope: Scope::BACKEND, changed_by: nil)
      with_connection do
        attempts = 0
        loop do
          attempts += 1
          begin
            row = Setting.find_or_initialize_by(environment: environment, scope: scope)
            row.enabled = enabled
            row.changed_by = changed_by
            row.save!
            return Record.new(enabled: row.enabled, changed_by: row.changed_by, updated_at: row.updated_at)
          rescue ActiveRecord::RecordNotUnique
            raise if attempts >= 3
          end
        end
      end
    end

    def table_exists?
      with_connection { Setting.table_exists? }
    end

    private

    # Runs the block with a leased connection and releases it afterwards unless
    # the calling thread already held one. The Sentry gate can run on threads
    # outside the Rails executor (Sidekiq, ad-hoc threads); this prevents
    # leaking pool connections from those threads.
    def with_connection(&block)
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end
end
