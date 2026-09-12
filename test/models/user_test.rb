require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "resolves the configured owner" do
    assert_equal users(:owner), User.owner
    assert_equal "admin@localfolio.com", User.owner.email_address
  end

  test "prefers the new caramelo owner over the legacy owner" do
    owner = User.create!(
      email_address: Caramelo::Environment::DEFAULT_OWNER_EMAIL,
      password: "password"
    )

    assert_equal owner, User.owner
  end

  test "raises when a custom configured owner does not exist" do
    configured_email = Rails.application.config.x.caramelo.owner_email
    Rails.application.config.x.caramelo.owner_email = "missing@example.com"

    assert_raises(ActiveRecord::RecordNotFound) { User.owner }
  ensure
    Rails.application.config.x.caramelo.owner_email = configured_email
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
