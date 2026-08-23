require "test_helper"

class IsoCurrencyValidatorTest < ActiveSupport::TestCase
  class CurrencyRecord
    include ActiveModel::Model

    attr_accessor :currency

    validates :currency, iso_currency: true
  end

  test "accepts supported BRL and USD codes" do
    assert_predicate CurrencyRecord.new(currency: "BRL"), :valid?
    assert_predicate CurrencyRecord.new(currency: "USD"), :valid?
  end

  test "rejects unknown and noncanonical codes" do
    assert_predicate CurrencyRecord.new(currency: "ZZZ"), :invalid?
    assert_predicate CurrencyRecord.new(currency: "BTC"), :invalid?
    assert_predicate CurrencyRecord.new(currency: "usd"), :invalid?
    assert_predicate CurrencyRecord.new(currency: nil), :invalid?
  end
end
