# frozen_string_literal: true

# RSpec wiring for Sentrifig::TestHelper. Require it from spec/rails_helper.rb
# (or a spec/support file) and tag examples or groups with :sentrifig:
#
#   RSpec.describe "Sentry switch", :sentrifig do
#     it "drops events while disabled" do
#       Sentrifig.disable!
#       Sentry.capture_message("hidden")
#       expect(sentry_error_events).to be_empty
#     end
#   end
require_relative "test_helper"

RSpec.configure do |config|
  config.include Sentrifig::TestHelper, :sentrifig

  config.around(:each, :sentrifig) do |example|
    setup_sentrifig_test
    example.run
  ensure
    teardown_sentrifig_test
  end
end
