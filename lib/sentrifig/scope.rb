# frozen_string_literal: true

module Sentrifig
  # The two independently switchable Sentry surfaces of one deployment.
  #
  # "backend" gates the Ruby SDK through Gate::PROCESSOR. "frontend" is
  # published to browser clients through GET <mount>/state and gates their own
  # Sentry SDK; nothing in this process reads it on a hot path.
  #
  # Deliberately a closed set rather than a free-form per-client string: an
  # unbounded set makes the settings table unbounded and the dashboard
  # unreviewable, and there is no way to tell a typo from a new client.
  module Scope
    BACKEND  = "backend"
    FRONTEND = "frontend"
    ALL      = [BACKEND, FRONTEND].freeze

    module_function

    # @raise [ArgumentError] a bad scope is a programming error at the call
    #   site, not an operational failure a host should rescue. The routes
    #   constrain the segment so it never reaches a user.
    def coerce(value)
      scope = value.to_s
      return scope if ALL.include?(scope)

      raise ::ArgumentError, "unknown sentrifig scope #{value.inspect}, expected one of #{ALL.join(', ')}"
    end
  end
end
