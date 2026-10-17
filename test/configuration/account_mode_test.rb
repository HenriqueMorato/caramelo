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

  test "defaults to public authentication" do
    assert_equal "public", Caramelo::Environment::DEFAULT_AUTHENTICATION_MODE
    assert_equal "public", Caramelo::Environment.authentication_mode
  end

  test "accepts password authentication" do
    previous = ENV["CARAMELO_AUTHENTICATION_MODE"]
    ENV["CARAMELO_AUTHENTICATION_MODE"] = " PASSWORD "

    assert_equal "password", Caramelo::Environment.authentication_mode
  ensure
    ENV["CARAMELO_AUTHENTICATION_MODE"] = previous
  end

  test "reports the configured authentication mode" do
    previous = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.authentication_mode = "public"

    assert_predicate Caramelo::AuthenticationMode, :public?
    assert_not_predicate Caramelo::AuthenticationMode, :password?

    Rails.application.config.x.caramelo.authentication_mode = "password"

    assert_not_predicate Caramelo::AuthenticationMode, :public?
    assert_predicate Caramelo::AuthenticationMode, :password?
  ensure
    Rails.application.config.x.caramelo.authentication_mode = previous
  end

  test "rejects an unsupported authentication mode" do
    previous = ENV["CARAMELO_AUTHENTICATION_MODE"]
    ENV["CARAMELO_AUTHENTICATION_MODE"] = "token"

    assert_raises(ArgumentError) { Caramelo::Environment.authentication_mode }
  ensure
    ENV["CARAMELO_AUTHENTICATION_MODE"] = previous
  end

  test "defaults to a strong configurable password policy" do
    policy = Caramelo::Environment.password_policy

    assert_equal 8, policy.fetch(:minimum_length)
    assert policy.fetch(:require_uppercase)
    assert policy.fetch(:require_lowercase)
    assert policy.fetch(:require_number)
    assert policy.fetch(:require_symbol)
  end

  test "accepts password policy overrides" do
    names = %w[
      CARAMELO_PASSWORD_MIN_LENGTH
      CARAMELO_PASSWORD_REQUIRE_UPPERCASE
      CARAMELO_PASSWORD_REQUIRE_LOWERCASE
      CARAMELO_PASSWORD_REQUIRE_NUMBER
      CARAMELO_PASSWORD_REQUIRE_SYMBOL
    ]
    previous = names.to_h { |name| [ name, ENV[name] ] }
    ENV["CARAMELO_PASSWORD_MIN_LENGTH"] = " 12 "
    ENV["CARAMELO_PASSWORD_REQUIRE_UPPERCASE"] = "false"
    ENV["CARAMELO_PASSWORD_REQUIRE_LOWERCASE"] = " TRUE "
    ENV["CARAMELO_PASSWORD_REQUIRE_NUMBER"] = "false"
    ENV["CARAMELO_PASSWORD_REQUIRE_SYMBOL"] = "true"

    assert_equal(
      {
        minimum_length: 12,
        require_uppercase: false,
        require_lowercase: true,
        require_number: false,
        require_symbol: true
      },
      Caramelo::Environment.password_policy
    )
  ensure
    names.each { |name| ENV[name] = previous.fetch(name) }
  end

  test "rejects malformed password policy settings" do
    previous = ENV["CARAMELO_PASSWORD_MIN_LENGTH"]
    ENV["CARAMELO_PASSWORD_MIN_LENGTH"] = "eight"

    assert_raises(ArgumentError) { Caramelo::Environment.password_policy }
  ensure
    ENV["CARAMELO_PASSWORD_MIN_LENGTH"] = previous
  end

  test "rejects password policy lengths outside bcrypt limits" do
    previous = ENV["CARAMELO_PASSWORD_MIN_LENGTH"]
    ENV["CARAMELO_PASSWORD_MIN_LENGTH"] = "73"

    assert_raises(ArgumentError) { Caramelo::Environment.password_policy }
  ensure
    ENV["CARAMELO_PASSWORD_MIN_LENGTH"] = previous
  end

  test "rejects password policy values other than true or false" do
    previous = ENV["CARAMELO_PASSWORD_REQUIRE_SYMBOL"]
    ENV["CARAMELO_PASSWORD_REQUIRE_SYMBOL"] = "yes"

    assert_raises(ArgumentError) { Caramelo::Environment.password_policy }
  ensure
    ENV["CARAMELO_PASSWORD_REQUIRE_SYMBOL"] = previous
  end
end
