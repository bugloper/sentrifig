# frozen_string_literal: true

require "test_helper"

module Sentrifig
  class StoreTest < ActiveSupport::TestCase
    setup { @store = Store.new }

    test "fetch returns nil when nothing is stored" do
      assert_nil @store.fetch("test")
    end

    test "write creates exactly one row and fetch reads it back" do
      record = @store.write("test", enabled: false, changed_by: "alice")

      assert_equal false, record.enabled
      assert_equal "alice", record.changed_by
      assert_equal 1, Setting.count

      fetched = @store.fetch("test")
      assert_equal false, fetched.enabled
      assert_equal "alice", fetched.changed_by
      assert_kind_of Time, fetched.updated_at
    end

    test "write updates the existing row rather than adding another" do
      @store.write("test", enabled: false, changed_by: "alice")
      @store.write("test", enabled: true, changed_by: "bob")

      assert_equal 1, Setting.count
      assert_equal true, @store.fetch("test").enabled
      assert_equal "bob", @store.fetch("test").changed_by
    end

    test "environments are isolated" do
      @store.write("production", enabled: false)

      assert_nil @store.fetch("test")
      assert_equal false, @store.fetch("production").enabled
      assert_equal 1, Setting.count
    end

    test "a racing insert is retried against the winner's row" do
      calls = 0
      original = Setting.method(:find_or_initialize_by)
      racing = lambda do |**args|
        calls += 1
        if calls == 1
          # Simulate another process inserting between our find and our insert.
          Setting.create!(environment: args[:environment], enabled: true, changed_by: "other")
          raise ActiveRecord::RecordNotUnique, "UNIQUE constraint failed"
        end
        original.call(**args)
      end

      Setting.stub(:find_or_initialize_by, racing) do
        record = @store.write("test", enabled: false, changed_by: "me")
        assert_equal false, record.enabled
      end

      assert_equal 2, calls
      assert_equal 1, Setting.count
      assert_equal "me", Setting.first.changed_by
    end

    test "persistent uniqueness violations are re-raised" do
      always_racing = ->(**) { raise ActiveRecord::RecordNotUnique, "UNIQUE constraint failed" }
      Setting.stub(:find_or_initialize_by, always_racing) do
        assert_raises(ActiveRecord::RecordNotUnique) { @store.write("test", enabled: false) }
      end
    end

    test "database errors propagate (Runtime handles degradation)" do
      Setting.stub(:where, ->(*) { raise ActiveRecord::StatementInvalid, "no such table" }) do
        assert_raises(ActiveRecord::StatementInvalid) { @store.fetch("test") }
      end
    end

    test "database enforces uniqueness; model enforces presence" do
      Setting.create!(environment: "test", enabled: true)
      assert_raises(ActiveRecord::RecordNotUnique) { Setting.create!(environment: "test", enabled: false) }
      assert_not Setting.new(environment: "", enabled: true).valid?
      assert_not Setting.new(environment: "x", enabled: nil).valid?
    end

    test "the two scopes are independent rows in one environment" do
      @store.write("production", scope: Scope::BACKEND, enabled: false, changed_by: "alice")
      @store.write("production", scope: Scope::FRONTEND, enabled: true, changed_by: "bob")

      assert_equal 2, Setting.where(environment: "production").count
      assert_equal false, @store.fetch("production", scope: Scope::BACKEND).enabled
      assert_equal true, @store.fetch("production", scope: Scope::FRONTEND).enabled
    end

    test "fetch and write default to the backend scope" do
      @store.write("production", enabled: false, changed_by: "alice")

      assert_equal Scope::BACKEND, Setting.find_by!(environment: "production").scope
      assert_equal false, @store.fetch("production").enabled
      assert_nil @store.fetch("production", scope: Scope::FRONTEND)
    end

    test "the unique index is on the pair, not on environment alone" do
      Setting.create!(environment: "production", scope: Scope::BACKEND, enabled: true)
      Setting.create!(environment: "production", scope: Scope::FRONTEND, enabled: true)

      assert_raises(ActiveRecord::RecordNotUnique) do
        Setting.insert_all!([{ environment: "production", scope: Scope::FRONTEND, enabled: false,
                               created_at: Time.now, updated_at: Time.now }])
      end
    end
  end
end
