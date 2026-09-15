# frozen_string_literal: true

module Sentrifig
  module Settings
    # One setting's schema: its type, its bounds, where its default comes from,
    # and how to turn operator input into a value.
    #
    # This is the single source of truth for the whole feature. The dashboard
    # renders its inputs from it, the model validates against it, the rake tasks
    # parse with it, and the browser payload is built from it -- so a bad value
    # is rejected identically however it arrives.
    class Definition
      TYPES = %i[boolean float integer string string_list].freeze

      attr_reader :key, :type, :range, :allowed, :default, :env, :description, :note

      # @param key [Symbol] stable identifier, also the storage key
      # @param type [Symbol] one of TYPES
      # @param default [Object, Proc] literal default, or a proc for a computed one
      # @param env [String, nil] environment variable that seeds the default
      # @param range [Range, nil] numeric bounds, inclusive
      # @param allowed [Array, nil] the complete set of permitted values
      # @param note [String, nil] a caveat an operator needs before changing it
      def initialize(key:, type:, description:, default: nil, env: nil, range: nil, allowed: nil, note: nil)
        raise ArgumentError, "unknown setting type #{type.inspect}" unless TYPES.include?(type)

        @key = key.to_sym
        @type = type
        @description = description
        @default = default
        @env = env
        @range = range
        @allowed = allowed
        @note = note
        freeze
      end

      # The value when nothing is stored: the environment variable if it is set
      # and parses, otherwise the literal default.
      def default_value
        raw = @env && ENV.fetch(@env, nil)
        unless raw.nil? || raw.to_s.strip.empty?
          value, error = cast(raw)
          return value if error.nil?
        end

        @default.is_a?(Proc) ? @default.call : @default
      end

      # True when an environment variable is set for this setting, so the UI can
      # show where a default came from.
      def env_present?
        !@env.nil? && !ENV.fetch(@env, nil).to_s.strip.empty?
      end

      # Turns operator input (always a String from a form, or an already-typed
      # value from the Ruby API) into a stored value.
      #
      # @return [Array(Object, String|nil)] the value, and an error message or nil
      def cast(raw)
        value = coerce(raw)
        return [nil, type_error(raw)] if value == :invalid

        if @range && !@range.cover?(value)
          return [nil, "must be between #{@range.first} and #{@range.last}"]
        end

        if @allowed
          rejected = Array(value) - @allowed
          return [nil, "must be one of: #{@allowed.join(', ')}"] unless rejected.empty?
        end

        [value, nil]
      end

      # @return [Object] the cast value
      # @raise [ValidationError]
      def cast!(raw)
        value, error = cast(raw)
        raise ValidationError, "#{key}: #{error}" if error

        value
      end

      def boolean? = @type == :boolean
      def list? = @type == :string_list
      # Lists are long (excluded_exceptions ships 20+ entries), so a single-line
      # input truncates them to uselessness. Render those as a textarea.
      def multiline? = list?
      def numeric? = @type == :float || @type == :integer

      # How to render this in a form.
      def input_type
        case @type
        when :boolean then "checkbox"
        when :float, :integer then "number"
        else "text"
        end
      end

      def step
        return nil unless numeric?

        @type == :integer ? 1 : "any"
      end

      # For display and for the JSON payload: lists become a comma-separated
      # string in a text field, everything else is itself.
      def to_form(value)
        list? ? Array(value).join(", ") : value
      end

      private

      def coerce(raw)
        case @type
        when :boolean then coerce_boolean(raw)
        when :float then coerce_float(raw)
        when :integer then coerce_integer(raw)
        when :string then coerce_string(raw)
        when :string_list then coerce_list(raw)
        end
      end

      def coerce_boolean(raw)
        return raw if raw == true || raw == false

        case raw.to_s.strip.downcase
        when "true", "1", "yes", "on" then true
        when "false", "0", "no", "off", "" then false
        else :invalid
        end
      end

      def coerce_float(raw)
        return raw.to_f if raw.is_a?(Numeric)

        Float(raw.to_s.strip)
      rescue ArgumentError, TypeError
        :invalid
      end

      def coerce_integer(raw)
        return raw.to_i if raw.is_a?(Integer)
        return :invalid if raw.is_a?(Float) && raw != raw.to_i

        Integer(raw.to_s.strip, 10)
      rescue ArgumentError, TypeError
        :invalid
      end

      def coerce_string(raw)
        value = raw.to_s.strip
        value.empty? ? nil : value
      end

      def coerce_list(raw)
        items = raw.is_a?(Array) ? raw : raw.to_s.split(",")
        items.map { |item| item.to_s.strip }.reject(&:empty?)
      end

      def type_error(raw)
        case @type
        when :boolean then "must be true or false, got #{raw.inspect}"
        when :float then "must be a number, got #{raw.inspect}"
        when :integer then "must be a whole number, got #{raw.inspect}"
        else "is invalid: #{raw.inspect}"
        end
      end
    end
  end
end
