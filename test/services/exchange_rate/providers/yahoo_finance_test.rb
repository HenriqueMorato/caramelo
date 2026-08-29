require "test_helper"

class ExchangeRate::Providers::YahooFinanceTest < ActiveSupport::TestCase
  test "normalizes a Yahoo currency pair into an exchange rate" do
    client = FakeClient.new
    provider = ExchangeRate::Providers::YahooFinance.new(client:)

    rate = provider.fetch(base_currency: "USD", quote_currency: "BRL")

    assert_equal "USD", rate.base_currency
    assert_equal "BRL", rate.quote_currency
    assert_equal BigDecimal("5.1234"), rate.rate
    assert_equal "yahoo_finance_fx", rate.provider
    assert_equal [ [ "USD", "BRL" ] ], client.requests
  end

  test "translates Yahoo failures into exchange-rate errors" do
    client = Object.new
    client.define_singleton_method(:rate) { |**| raise MarketData::YahooFinance::Error, "unavailable" }
    provider = ExchangeRate::Providers::YahooFinance.new(client:)

    assert_raises(ExchangeRate::InvalidValue) do
      provider.fetch(base_currency: "USD", quote_currency: "BRL")
    end
  end

  FakeClient = Struct.new(:requests) do
    def initialize
      super([])
    end

    def rate(base_currency:, quote_currency:)
      requests << [ base_currency, quote_currency ]
      MarketData::YahooFinance::FxClient::Rate.new(rate: BigDecimal("5.1234"), observed_at: Time.current)
    end
  end
end
