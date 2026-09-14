# frozen_string_literal: true

module SeliseSentry
  class Error < StandardError; end

  # Raised by SeliseSentry.configure / Configuration#validate! for invalid settings.
  class ConfigurationError < Error; end

  # Raised by enable! / disable! when the state could not be persisted
  # (database unavailable, table missing, ...). The original exception is
  # available through #cause.
  class PersistenceError < Error; end
end
