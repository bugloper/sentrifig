# frozen_string_literal: true

module SeliseSentry
  # One row per environment. Use SeliseSentry.enable! / disable! rather than
  # writing this model directly so the in-process cache is updated too.
  class Setting < ::ActiveRecord::Base
    self.table_name = "selise_sentry_settings"

    # Uniqueness of environment is enforced by the database index, not by a
    # validation: a validation-level check races under concurrent writers
    # (both pass, one insert fails). Store#write retries on RecordNotUnique.
    validates :environment, presence: true
    validates :enabled, inclusion: { in: [true, false] }
  end
end
