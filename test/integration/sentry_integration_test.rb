# frozen_string_literal: true

require "test_helper"

# End-to-end behaviour of the runtime gate against sentry-ruby / sentry-rails,
# using Sentry's own DummyTransport: events that reach the transport would
# have been sent to Sentry.
class SentryIntegrationTest < ActionDispatch::IntegrationTest
  include Sentrifig::TestHelper

  setup do
    Sentrifig::Setting.delete_all
    Sentrifig.reset!
    configure_sentrifig
    setup_sentrifig_test do |config|
      config.before_send = lambda do |event, _hint|
        @before_send_calls = (@before_send_calls || 0) + 1
        event
      end
    end
  end

  teardown do
    teardown_sentrifig_test
    Sentrifig.reset!
  end

  # Requests also produce TransactionEvents (traces_sample_rate = 1.0 in the
  # dummy app); these assertions are about error events.
  def error_events = sentry_error_events

  test "Sentry.capture_exception reaches the transport while enabled" do
    Sentry.capture_exception(RuntimeError.new("on"))
    assert_equal 1, sentry_events.size
    assert_includes extract_sentry_exceptions(last_sentry_event).first.value, "on"
    assert_equal 1, @before_send_calls, "the application's before_send still runs"
  end

  test "Sentry.capture_exception is discarded while disabled" do
    Sentrifig.disable!
    result = Sentry.capture_exception(RuntimeError.new("off"))
    assert_nil result
    assert_empty sentry_events
    assert_nil @before_send_calls, "before_send is not even reached"
    assert_equal 1, sentry_transport.discarded_events[[:event_processor, "error"]]
  end

  test "capture_message is discarded while disabled" do
    Sentrifig.disable!
    Sentry.capture_message("off")
    assert_empty sentry_events
  end

  test "transactions are discarded while disabled and resume when enabled" do
    Sentrifig.disable!
    tx = Sentry.start_transaction(name: "job", op: "test")
    tx.finish
    assert_empty sentry_events

    Sentrifig.enable!
    tx = Sentry.start_transaction(name: "job", op: "test")
    tx.finish
    assert_equal ["transaction"], sentry_events.map(&:type)
  end

  test "runtime toggle without restart: off, on, off again in one process" do
    Sentry.capture_message("1")
    Sentrifig.disable!
    Sentry.capture_message("2")
    Sentrifig.enable!
    Sentry.capture_message("3")
    Sentrifig.disable!
    Sentry.capture_message("4")

    assert_equal %w[1 3], sentry_events.map(&:message)
  end

  test "breadcrumbs, tags, user and context keep working while disabled and appear once re-enabled" do
    Sentrifig.disable!
    Sentry.add_breadcrumb(Sentry::Breadcrumb.new(message: "while off"))
    Sentry.set_tags(feature: "gate")
    Sentry.set_user(id: 42)
    Sentry.set_extras(step: "disabled")
    Sentry.capture_message("dropped")
    assert_empty sentry_events

    Sentrifig.enable!
    Sentry.capture_message("kept")

    event = last_sentry_event
    assert_equal "kept", event.message
    assert_includes event.breadcrumbs.members.map(&:message), "while off"
    assert_equal "gate", event.tags[:feature]
    assert_equal 42, event.user[:id]
    assert_equal "disabled", event.extra[:step]
  end

  test "an unhandled Rails controller exception is captured while enabled" do
    get "/boom"
    assert_response :internal_server_error
    assert_equal 1, error_events.size
    assert_includes extract_sentry_exceptions(error_events.first).first.value, "boom from the demo app"
  end

  test "an unhandled Rails controller exception is not captured while disabled" do
    Sentrifig.disable!
    get "/boom"
    assert_response :internal_server_error
    assert_empty sentry_events, "neither the error nor the request transaction is sent"
  end

  test "Rails.error.report respects the runtime state" do
    Rails.error.report(RuntimeError.new("handled on"), handled: true)
    assert_equal 1, error_events.size

    Sentrifig.disable!
    Rails.error.report(RuntimeError.new("handled off"), handled: true)
    assert_equal 1, error_events.size

    get "/report"
    assert_response :success
    assert_equal 1, error_events.size
  end

  test "toggling through the mounted UI immediately affects capture in the same process" do
    post "/sentrifig/disable", headers: basic_auth
    assert_redirected_to "/sentrifig/"
    Sentry.capture_exception(RuntimeError.new("after ui disable"))
    assert_empty sentry_events

    post "/sentrifig/enable", headers: basic_auth
    Sentry.capture_exception(RuntimeError.new("after ui enable"))
    assert_equal 1, error_events.size
  end

  test "a change made by another process is picked up after the cache TTL" do
    configure_sentrifig(cache_ttl: 60)
    Sentry.capture_message("before")
    assert_equal 1, sentry_events.size

    # Another process writes directly to the shared database.
    Sentrifig::Setting.create!(environment: "test", enabled: false, changed_by: "other-process")
    Sentry.capture_message("still cached")
    assert_equal 2, sentry_events.size, "inside the TTL the cached value is used"

    # Simulate the TTL elapsing by swapping the runtime's clock forward.
    Sentrifig.runtime.instance_variable_set(:@next_refresh_at, 0.0)
    Sentry.capture_message("after ttl")
    assert_equal 2, sentry_events.size
  end

  test "Sentry.capture_exception never raises even if the store is broken" do
    Sentrifig::Setting.stub(:where, ->(*) { raise ActiveRecord::StatementInvalid, "no such table" }) do
      assert_nothing_raised { Sentry.capture_exception(RuntimeError.new("db down")) }
    end
    assert_equal 1, sentry_events.size, "fails open: default is enabled"
  end
end
