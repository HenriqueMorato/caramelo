require "test_helper"

class MoneyConfigurationTest < ActiveSupport::TestCase
  class MoneyRecord < ApplicationRecord
    self.table_name = "users"

    attribute :amount_cents, :integer
    attribute :amount_currency, :string

    monetize :amount_cents, with_model_currency: :amount_currency
  end

  test "uses the reporting currency as the default" do
    reporting_currency = Rails.configuration.x.caramelo.reporting_currency

    assert_equal "BRL", reporting_currency
    assert_equal reporting_currency, Money.default_currency.iso_code
    assert_equal reporting_currency, MoneyRails.currency_column[:default]
  end

  test "exposes precise BRL and USD values through an Active Record model" do
    brl = MoneyRecord.new(amount_cents: 12_345, amount_currency: "BRL").amount
    usd = MoneyRecord.new(amount_cents: 12_345, amount_currency: "USD").amount

    assert_instance_of Money, brl
    assert_instance_of Money, usd
    assert_equal 12_345, brl.fractional
    assert_equal 12_345, usd.fractional
    assert_equal "BRL", brl.currency.iso_code
    assert_equal "USD", usd.currency.iso_code
    refute_equal brl, usd
  end

  test "configures monetized columns for integer storage and strict parsing" do
    assert_equal :integer, MoneyRails.amount_column[:type]
    assert_equal BigDecimal::ROUND_HALF_UP, Money.rounding_mode
    assert MoneyRails.raise_error_on_money_parsing
  end
end
