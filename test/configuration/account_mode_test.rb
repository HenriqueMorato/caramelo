require "test_helper"

class AccountModeTest < ActiveSupport::TestCase
  test "defaults to single account mode" do
    assert_equal "single", Caramelo::Environment::DEFAULT_ACCOUNT_MODE
    assert_predicate Caramelo::AccountMode, :single?
    assert_not_predicate Caramelo::AccountMode, :multi?
  end

  test "accepts the configured multi account mode" do
    previous = ENV["CARAMELO_ACCOUNT_MODE"]
    ENV["CARAMELO_ACCOUNT_MODE"] = " MULTI "

    assert_equal "multi", Caramelo::Environment.account_mode
  ensure
    ENV["CARAMELO_ACCOUNT_MODE"] = previous
  end

  test "treats a blank setting as the default" do
    previous = ENV["CARAMELO_ACCOUNT_MODE"]
    ENV["CARAMELO_ACCOUNT_MODE"] = "  "

    assert_equal "single", Caramelo::Environment.account_mode
  ensure
    ENV["CARAMELO_ACCOUNT_MODE"] = previous
  end

  test "rejects an unsupported account mode" do
    previous = ENV["CARAMELO_ACCOUNT_MODE"]
    ENV["CARAMELO_ACCOUNT_MODE"] = "shared"

    assert_raises(ArgumentError) { Caramelo::Environment.account_mode }
  ensure
    ENV["CARAMELO_ACCOUNT_MODE"] = previous
  end
end
