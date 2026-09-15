# frozen_string_literal: true

require "test_helper"

module Sentrifig
  class SettingsSchemaTest < ActiveSupport::TestCase
    def definition(scope, key) = Settings::Schema.find(scope, key)

    # --- casting and validation --------------------------------------------

    test "floats accept numbers and numeric strings, and reject the rest" do
      rate = definition(Scope::BACKEND, :sample_rate)

      assert_equal [0.5, nil], rate.cast("0.5")
      assert_equal [0.5, nil], rate.cast(0.5)
      assert_equal [1.0, nil], rate.cast(1)
      assert_equal [0.0, nil], rate.cast("0")

      _, error = rate.cast("half")
      assert_match(/must be a number/, error)
    end

    test "floats are held to their range" do
      rate = definition(Scope::BACKEND, :sample_rate)

      _, error = rate.cast("1.5")
      assert_match(/must be between 0.0 and 1.0/, error)
      _, error = rate.cast("-0.1")
      assert_match(/must be between 0.0 and 1.0/, error)
    end

    test "integers reject fractions rather than silently truncating" do
      crumbs = definition(Scope::BACKEND, :max_breadcrumbs)

      assert_equal [50, nil], crumbs.cast("50")

      _, error = crumbs.cast("12.5")
      assert_match(/must be a whole number/, error)

      _, error = crumbs.cast("101")
      assert_match(/must be between 0 and 100/, error)
    end

    test "booleans accept the usual spellings and reject anything else" do
      pii = definition(Scope::BACKEND, :send_default_pii)

      %w[true 1 yes on TRUE].each { |raw| assert_equal [true, nil], pii.cast(raw), raw }
      %w[false 0 no off].each { |raw| assert_equal [false, nil], pii.cast(raw), raw }
      assert_equal [false, nil], pii.cast("")

      _, error = pii.cast("maybe")
      assert_match(/must be true or false/, error)
    end

    # The string "false" is truthy in Ruby; assigning it raw is the bug that had
    # production sending PII for months. This is the regression test for it.
    test "the string false is false, not truthy" do
      value, = definition(Scope::BACKEND, :send_default_pii).cast("false")

      assert_equal false, value
      assert_not value
    end

    test "lists split, strip and drop blanks" do
      excluded = definition(Scope::BACKEND, :excluded_exceptions)

      assert_equal [%w[A::B C::D], nil], excluded.cast(" A::B ,C::D , ")
      # Newlines are what the textarea submits; a mix of both must also work,
      # so pasting an old comma-separated value still does the obvious thing.
      assert_equal [%w[A::B C::D], nil], excluded.cast("A::B\nC::D\n")
      assert_equal [%w[A B C], nil], excluded.cast("A\nB, C")
      assert_equal [[], nil], excluded.cast("")
      assert_equal [%w[A B], nil], excluded.cast(%w[A B])
    end

    test "a blank string clears an optional string setting" do
      assert_equal [nil, nil], definition(Scope::BACKEND, :release).cast("  ")
    end

    # --- defaults ------------------------------------------------------------

    test "an environment variable seeds the default" do
      with_env("SENTRY_SAMPLE_RATE" => "0.25") do
        assert_in_delta 0.25, definition(Scope::BACKEND, :sample_rate).default_value
        assert definition(Scope::BACKEND, :sample_rate).env_present?
      end
    end

    test "an unparseable environment variable falls back to the literal default" do
      with_env("SENTRY_SAMPLE_RATE" => "loads") do
        assert_in_delta 1.0, definition(Scope::BACKEND, :sample_rate).default_value
      end
    end

    test "an out-of-range environment variable falls back rather than being applied" do
      with_env("SENTRY_SAMPLE_RATE" => "7") do
        assert_in_delta 1.0, definition(Scope::BACKEND, :sample_rate).default_value
      end
    end

    # --- schema level --------------------------------------------------------

    test "casting a hash reports every failing key at once" do
      values, errors = Settings::Schema.cast(Scope::BACKEND,
                                             "sample_rate" => "2", "max_breadcrumbs" => "x", "release" => "v1")

      assert_equal({ release: "v1" }, values)
      assert_equal %i[sample_rate max_breadcrumbs].sort, errors.keys.sort
    end

    test "an unknown key is an error, not silently dropped" do
      _, errors = Settings::Schema.cast(Scope::BACKEND, "nonsense" => "1")

      assert_match(/is not a setting for the backend scope/, errors[:nonsense])
    end

    test "backend-only settings are not in the frontend scope, and the reverse" do
      assert_includes Settings::Schema.keys(Scope::BACKEND), :excluded_exceptions
      assert_not_includes Settings::Schema.keys(Scope::FRONTEND), :excluded_exceptions

      assert_includes Settings::Schema.keys(Scope::FRONTEND), :replays_session_sample_rate
      assert_not_includes Settings::Schema.keys(Scope::BACKEND), :replays_session_sample_rate
    end

    # Every setting here must be one the SDK reads after init. A setting the SDK
    # captures at client-build time would render as editable and do nothing.
    test "every backend setting is assignable on a live Sentry configuration" do
      Settings::Schema.for_scope(Scope::BACKEND).each do |definition|
        assert Sentry.configuration.respond_to?(:"#{definition.key}="),
               "#{definition.key} is not settable on Sentry::Configuration"
      end
    end

    test "form rendering hints match the types" do
      assert_equal "checkbox", definition(Scope::BACKEND, :send_default_pii).input_type
      assert_equal "number", definition(Scope::BACKEND, :sample_rate).input_type
      assert_equal "any", definition(Scope::BACKEND, :sample_rate).step
      assert_equal 1, definition(Scope::BACKEND, :max_breadcrumbs).step
      assert_equal "text", definition(Scope::BACKEND, :excluded_exceptions).input_type
      excluded = definition(Scope::BACKEND, :excluded_exceptions)
      # One entry per line in the form; commas only where newlines would wreck
      # the layout, such as a terminal.
      assert_equal "A\nB", excluded.to_form(%w[A B])
      assert_equal "A, B", excluded.to_display(%w[A B])
      assert excluded.multiline?
      # Tall enough for the content plus a spare line, capped.
      assert_equal 3, excluded.rows_for(%w[A B])
      assert_equal 12, excluded.rows_for(("a".."z").to_a)
    end
  end

  class SettingsApiTest < ActiveSupport::TestCase
    test "settings resolve to their defaults with nothing stored" do
      assert_equal Settings::Schema.keys(Scope::BACKEND).sort, Sentrifig.settings.keys.sort
      assert_in_delta 1.0, Sentrifig.settings[:sample_rate]
    end

    test "an override is stored, resolved and applied to the live SDK" do
      Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "0.5" }, by: "alice")

      assert_in_delta 0.5, Sentrifig.settings[:sample_rate]
      assert_in_delta 0.5, Sentry.configuration.sample_rate
      assert_equal [:sample_rate], Sentrifig.runtime(Scope::BACKEND).overridden_keys
    end

    test "only the changed key is stored, so the rest keep following their defaults" do
      Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "0.5" }, by: "alice")

      stored = Setting.find_by!(environment: "test", scope: Scope::BACKEND).values

      assert_equal %w[sample_rate], stored.keys
    end

    test "resetting restores the default and stops overriding" do
      Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "0.5" }, by: "alice")
      Sentrifig.reset_setting!(Scope::BACKEND, :sample_rate, by: "alice")

      assert_in_delta 1.0, Sentrifig.settings[:sample_rate]
      assert_empty Sentrifig.runtime(Scope::BACKEND).overridden_keys
    end

    test "an invalid value raises and writes nothing" do
      error = assert_raises(ValidationError) do
        Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "2" }, by: "alice")
      end

      assert_match(/sample_rate must be between/, error.message)
      assert_equal 0, Setting.count
      assert_in_delta 1.0, Sentrifig.settings[:sample_rate]
    end

    test "one invalid value rejects the whole submission" do
      assert_raises(ValidationError) do
        Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "0.5", max_breadcrumbs: "nope" }, by: "alice")
      end

      assert_in_delta 1.0, Sentrifig.settings[:sample_rate], 0.001,
                      "a partial write would be worse than none"
    end

    test "resetting an unknown key raises rather than writing a junk row" do
      assert_raises(ValidationError) { Sentrifig.reset_setting!(Scope::BACKEND, :nonsense, by: "alice") }
      assert_equal 0, Setting.count
    end

    test "the scopes keep separate settings" do
      Sentrifig.update_settings!(Scope::FRONTEND, { sample_rate: "0.25" }, by: "alice")

      assert_in_delta 0.25, Sentrifig.settings(Scope::FRONTEND)[:sample_rate]
      assert_in_delta 1.0, Sentrifig.settings(Scope::BACKEND)[:sample_rate]
    end

    test "settings and the switch live on one row and do not disturb each other" do
      Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "0.5" }, by: "alice")
      Sentrifig.disable!(by: "alice")

      assert_not Sentrifig.enabled?
      assert_in_delta 0.5, Sentrifig.settings[:sample_rate]
      assert_equal 1, Setting.where(environment: "test", scope: Scope::BACKEND).count
    end

    test "changes are logged with who made them" do
      logger, log = capturing_logger
      configure_sentrifig(logger: logger)

      Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "0.5" }, by: "alice")

      assert_match(/settings changed scope=backend environment=test by=alice sample_rate=0.5/, log.string)
    end

    test "a frontend change does not touch the Ruby SDK" do
      before = Sentry.configuration.sample_rate

      Sentrifig.update_settings!(Scope::FRONTEND, { sample_rate: "0.25" }, by: "alice")

      assert_equal before, Sentry.configuration.sample_rate
    end

    # The application's own config.sentry { } block is the baseline, so a
    # setting nobody has overridden must not be reset to the schema's literal.
    test "applying overrides leaves the application's own configuration alone" do
      assert_includes Sentry.configuration.enabled_environments, "test"

      Sentrifig.update_settings!(Scope::BACKEND, { sample_rate: "0.5" }, by: "alice")

      assert_includes Sentry.configuration.enabled_environments, "test",
                      "the dummy app's enabled_environments must survive a settings write"
    end
  end
end
