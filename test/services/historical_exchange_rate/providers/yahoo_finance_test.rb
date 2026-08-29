require "test_helper"

class HistoricalExchangeRate::Providers::YahooFinanceTest < ActiveSupport::TestCase
  test "normalizes the requested pair and maps client rates to observations" do
    client = FakeClient.new(
      MarketData::YahooFinance::FxHistoryClient::Rate.new(
        rate: BigDecimal("5.432109876543"), rate_date: Date.new(2026, 8, 28),
        observed_at: Time.utc(2026, 8, 28, 21)
      )
    )
    provider = HistoricalExchangeRate::Providers::YahooFinance.new(client:)

    observations = provider.fetch(base_currency: " usd ", quote_currency: "brl", from: Date.new(2026, 8, 28), to: Date.new(2026, 8, 28))

    assert_equal "USD", observations.first.base_currency
    assert_equal "BRL", observations.first.quote_currency
    assert_equal "yahoo_finance_fx", observations.first.provider
    assert_equal BigDecimal("5.432109876543"), observations.first.rate
    assert_equal [ "USD", "BRL" ], client.requested_pair
  end

  test "rejects same-currency requests before calling the client" do
    client = FakeClient.new
    provider = HistoricalExchangeRate::Providers::YahooFinance.new(client:)

    assert_raises(ArgumentError) do
      provider.fetch(base_currency: "BRL", quote_currency: "BRL", from: Date.current, to: Date.current)
    end
    assert_nil client.requested_pair
  end

  private

  class FakeClient
    attr_reader :requested_pair

    def initialize(rate = nil)
      @rate = rate
    end

    def daily_rates(base_currency:, quote_currency:, from:, to:)
      @requested_pair = [ base_currency, quote_currency ]
      [ @rate ].compact
    end
  end
end
