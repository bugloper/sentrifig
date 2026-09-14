# frozen_string_literal: true

module Sentrifig
  # One row per (environment, scope). Use Sentrifig.enable! / disable! rather
  # than writing this model directly so the in-process cache is updated too.
  class Setting < ::ActiveRecord::Base
    self.table_name = "sentrifig_settings"

    # Uniqueness of (environment, scope) is enforced by the database index, not
    # by a validation: a validation-level check races under concurrent writers
    # (both pass, one insert fails). Store#write retries on RecordNotUnique.
    #
    # No database CHECK constraint on scope: MySQL 5.7 silently ignores check
    # constraints, so a host-portable gem should not pretend to have one. The
    # column is only ever written through Store, which is only ever called with
    # a coerced scope.
    validates :environment, presence: true
    validates :scope, inclusion: { in: Scope::ALL }
    validates :enabled, inclusion: { in: [true, false] }
  end
end
