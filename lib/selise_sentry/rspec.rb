# frozen_string_literal: true

# RSpec wiring for SeliseSentry::TestHelper. Require it from spec/rails_helper.rb
# (or a spec/support file) and tag examples or groups with :selise_sentry:
#
#   RSpec.describe "Sentry switch", :selise_sentry do
#     it "drops events while disabled" do
#       SeliseSentry.disable!
#       Sentry.capture_message("hidden")
#       expect(sentry_error_events).to be_empty
#     end
#   end
require_relative "test_helper"

RSpec.configure do |config|
  config.include SeliseSentry::TestHelper, :selise_sentry

  config.around(:each, :selise_sentry) do |example|
    setup_selise_sentry_test
    example.run
  ensure
    teardown_selise_sentry_test
  end
end
