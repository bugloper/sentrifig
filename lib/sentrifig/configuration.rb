# frozen_string_literal: true

module Sentrifig
  # Public configuration for sentrifig.
  #
  #   Sentrifig.configure do |config|
  #     config.username = ENV.fetch("SENTRIFIG_USERNAME")
  #     config.password = ENV.fetch("SENTRIFIG_PASSWORD")
  #   end
  class Configuration
    DEFAULT_CACHE_TTL = 5 # seconds
    DEFAULT_CLIENT_POLL_INTERVAL = 60 # seconds
    USERNAME_ENV = "SENTRIFIG_USERNAME"
    PASSWORD_ENV = "SENTRIFIG_PASSWORD"

    # HTTP Basic Auth credentials for the mounted UI. Default to the
    # SENTRIFIG_USERNAME / SENTRIFIG_PASSWORD environment variables so
    # a host application needs no initializer. Both are required for the UI to
    # be reachable; when either is blank every engine request is refused with
    # 401 and an error is logged.
    attr_accessor :username, :password

    # What Sentrifig.enabled? returns when the database holds no record for
    # the current environment (or cannot be reached and nothing was ever loaded).
    # Defaults to true so installing the gem never silently disables Sentry.
    attr_reader :enabled_by_default

    # How long (seconds) a process trusts its in-memory copy of the state
    # before re-reading the database. Bounds cross-process propagation delay.
    # 0 means re-read on every check (useful in tests, not in production).
    attr_reader :cache_ttl

    # Key under which the state is stored. Defaults to the environment Sentry
    # itself reports (Sentry.configuration.environment, e.g. "staging" even
    # when Rails.env is "production"), falling back to Rails.env before Sentry
    # is initialised. Override only when that is not the right split.
    attr_reader :environment

    # Logger used for operational messages ("[sentrifig] Sentry disabled").
    # Defaults to Rails.logger.
    attr_writer :logger

    # Whether the engine calls Sentry.init with the Selise defaults
    # (SentrySetup) after the application's initializers. Default true. Set to
    # false to keep an application's own Sentry.init.
    attr_reader :initialize_sentry

    # Blocks registered with #sentry, applied to the Sentry configuration after
    # the defaults, in registration order.
    attr_reader :sentry_overrides

    # Authenticates browser requests to GET <mount>/state. Receives the
    # ActionDispatch::Request and returns truthy to allow, falsey to refuse.
    #
    # The gem cannot know how the host authenticates its users (JWT, session,
    # Doorkeeper), so the host supplies the check:
    #
    #   config.client_authenticator = ->(request) { MyAuth.user_from(request).present? }
    #
    # It receives the request rather than a controller on purpose: the host
    # cannot call render, cannot depend on this gem's controller ancestry, and
    # can unit-test the lambda with ActionDispatch::TestRequest.create. The cost
    # is real -- there is no current_user or authenticate_user! helper, so a
    # host whose auth is a before_action mixin must restate it at request level.
    #
    # Unset means no browser client can read the state: every request to that
    # endpoint is refused with 401 and an error is logged. Fail closed, matching
    # how missing Basic credentials are treated.
    attr_reader :client_authenticator

    # Seconds a browser client should wait between polls, published in the state
    # response. Deliberately NOT cache_ttl: that is how long *this process*
    # trusts its memory before one indexed query, and handing 5 seconds to every
    # open browser tab would mean twelve requests a minute per tab, forever.
    attr_reader :client_poll_interval

    def initialize
      @username = ENV.fetch(USERNAME_ENV, nil)
      @password = ENV.fetch(PASSWORD_ENV, nil)
      @enabled_by_default = true
      @cache_ttl = DEFAULT_CACHE_TTL
      @environment = nil
      @logger = nil
      @initialize_sentry = true
      @sentry_overrides = []
      @client_authenticator = nil
      @client_poll_interval = DEFAULT_CLIENT_POLL_INTERVAL
    end

    def initialize_sentry=(value)
      unless value == true || value == false
        raise ConfigurationError, "initialize_sentry must be true or false, got #{value.inspect}"
      end

      @initialize_sentry = value
    end

    # Registers application-specific Sentry settings applied on top of the
    # Selise defaults when the engine initialises Sentry.
    #
    #   config.sentry do |sentry|
    #     sentry.excluded_exceptions += ["MyApp::Ignored"]
    #   end
    #
    # @yieldparam sentry [Sentry::Configuration]
    def sentry(&block)
      raise ConfigurationError, "sentry requires a block" unless block

      @sentry_overrides << block
      nil
    end

    def enabled_by_default=(value)
      unless value == true || value == false
        raise ConfigurationError, "enabled_by_default must be true or false, got #{value.inspect}"
      end

      @enabled_by_default = value
    end

    def cache_ttl=(value)
      unless value.is_a?(Numeric) && value >= 0
        raise ConfigurationError, "cache_ttl must be a non-negative number of seconds, got #{value.inspect}"
      end

      @cache_ttl = value
    end

    def environment=(value)
      value = value.to_s
      raise ConfigurationError, "environment must not be blank" if value.strip.empty?

      @environment = value
    end

    def environment
      @environment || default_environment
    end

    def logger
      @logger || default_logger
    end

    def client_authenticator=(value)
      unless value.nil? || value.respond_to?(:call)
        raise ConfigurationError, "client_authenticator must respond to #call, got #{value.inspect}"
      end

      if value && value.respond_to?(:arity) && value.arity != 1 && !value.arity.negative?
        raise ConfigurationError,
              "client_authenticator must accept one argument (the request), got arity #{value.arity}"
      end

      @client_authenticator = value
    end

    def client_poll_interval=(value)
      unless value.is_a?(Numeric) && value.positive?
        raise ConfigurationError,
              "client_poll_interval must be a positive number of seconds, got #{value.inspect}"
      end

      @client_poll_interval = value
    end

    def client_authenticator_configured?
      !@client_authenticator.nil?
    end

    def credentials_configured?
      present?(username) && present?(password)
    end

    # Raises ConfigurationError for combinations that cannot work. Missing
    # credentials are deliberately *not* a boot-time error: an application must
    # keep booting (and keep reporting to Sentry) even if the operator forgot
    # to configure the UI. The UI itself refuses access instead.
    def validate!
      raise ConfigurationError, "environment must not be blank" if environment.to_s.strip.empty?
      raise ConfigurationError, "username must be a String" unless username.nil? || username.is_a?(String)
      raise ConfigurationError, "password must be a String" unless password.nil? || password.is_a?(String)

      true
    end

    private

    def present?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    def default_environment
      sentry_environment || rails_environment
    end

    def sentry_environment
      return nil unless defined?(::Sentry) && ::Sentry.initialized?

      value = ::Sentry.configuration.environment.to_s
      value.strip.empty? ? nil : value
    rescue StandardError
      nil
    end

    def rails_environment
      if defined?(::Rails) && ::Rails.respond_to?(:env)
        ::Rails.env.to_s
      else
        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      end
    end

    def default_logger
      if defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
        ::Rails.logger
      else
        @fallback_logger ||= ::Logger.new($stdout)
      end
    end
  end
end
