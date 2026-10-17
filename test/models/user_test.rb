require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "resolves the configured owner" do
    assert_equal users(:owner), User.owner
    assert_equal "admin@caramelo.local", User.owner.email_address
  end

  test "allows the implicit owner only in single-account mode" do
    assert_equal users(:owner), User.default_owner
  end

  test "requires an explicit account in multi-account mode" do
    previous = Rails.application.config.x.caramelo.account_mode
    Rails.application.config.x.caramelo.account_mode = "multi"

    error = assert_raises(ArgumentError) { User.default_owner }

    assert_equal "owner must be provided in multi-account mode", error.message
  ensure
    Rails.application.config.x.caramelo.account_mode = previous
  end

  test "tracks whether a real password has been configured" do
    user = users(:owner)

    assert_predicate user, :password_configured?
    user.update!(password_configured_at: nil)
    assert_not user.password_configured?
  end

  test "requires the configured password policy" do
    user = User.new(
      email_address: "policy@example.com",
      password: "weak",
      password_confirmation: "weak",
      password_configured_at: Time.current
    )

    assert_not user.valid?
    assert_includes user.errors.full_messages_for(:password), "Password is too short (minimum is 8 characters)"
    assert_includes user.errors.full_messages_for(:password), "Password must include an uppercase letter"
    assert_includes user.errors.full_messages_for(:password), "Password must include a number"
    assert_includes user.errors.full_messages_for(:password), "Password must include a symbol"
  end

  test "rejects whitespace-only configured passwords" do
    user = User.new(
      email_address: "blank-password@example.com",
      password: " ",
      password_confirmation: " ",
      password_configured_at: Time.current
    )

    assert_not user.valid?
    assert user.errors.of_kind?(:password, :blank)
  end

  test "accepts a password that meets the configured policy" do
    user = User.new(
      email_address: "policy@example.com",
      password: "Strongpass1!",
      password_confirmation: "Strongpass1!",
      password_configured_at: Time.current
    )

    assert_predicate user, :valid?
  end

  test "does not enforce the policy on an unconfigured password placeholder" do
    user = User.new(
      email_address: "placeholder@example.com",
      password: "password",
      password_confirmation: "password"
    )

    assert_predicate user, :valid?
  end

  test "honors disabled password requirements" do
    previous = Rails.application.config.x.caramelo.password_policy
    Rails.application.config.x.caramelo.password_policy = {
      minimum_length: 1,
      require_uppercase: false,
      require_lowercase: false,
      require_number: false,
      require_symbol: false
    }
    user = User.new(
      email_address: "relaxed-policy@example.com",
      password: "x",
      password_confirmation: "x",
      password_configured_at: Time.current
    )

    assert_predicate user, :valid?
  ensure
    Rails.application.config.x.caramelo.password_policy = previous
  end

  test "raises when a custom configured owner does not exist" do
    configured_email = Rails.application.config.x.caramelo.owner_email
    Rails.application.config.x.caramelo.owner_email = "missing@example.com"

    assert_raises(ActiveRecord::RecordNotFound) { User.owner }
  ensure
    Rails.application.config.x.caramelo.owner_email = configured_email
  end

  test "detects an owner email mismatch when another account exists" do
    configured_email = Rails.application.config.x.caramelo.owner_email
    Rails.application.config.x.caramelo.owner_email = "missing@example.com"

    assert_predicate User, :owner_configuration_conflict?
  ensure
    Rails.application.config.x.caramelo.owner_email = configured_email
  end

  test "does not report an owner email conflict for the configured owner" do
    assert_not User.owner_configuration_conflict?
  end

  test "defaults reporting currency to BRL" do
    assert_equal "BRL", User.new.reporting_currency
    assert_equal "BRL", users(:owner).reporting_currency
  end

  test "normalizes and persists supported reporting currencies" do
    user = users(:owner)

    ReportingCurrency::SUPPORTED_CODES.each do |currency|
      user.update!(reporting_currency: " #{currency.downcase} ")

      assert_equal currency, user.reload.reporting_currency
    end
  end

  test "rejects missing malformed and unlisted reporting currencies" do
    user = users(:owner)

    [ nil, "", "US", "USDD", "ZZZ", "BTC", "XAU" ].each do |currency|
      user.reporting_currency = currency

      assert_not user.valid?, "Expected #{currency.inspect} to be invalid"
      assert user.errors.of_kind?(:reporting_currency, :inclusion)
    end
  end

  test "reporting currency belongs to each user" do
    users(:owner).update!(reporting_currency: "USD")

    assert_equal "BRL", users(:one).reload.reporting_currency
  end

  test "database rejects null and malformed reporting currency" do
    assert_raises(ActiveRecord::NotNullViolation) do
      users(:owner).update_column(:reporting_currency, nil)
    end

    assert_raises(ActiveRecord::StatementInvalid) do
      User.connection.execute("UPDATE users SET reporting_currency = 'usd' WHERE id = #{users(:owner).id}")
    end
  end
end
