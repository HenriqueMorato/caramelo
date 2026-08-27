require "test_helper"

class MarketPrice::Providers::YahooFinanceTest < ActiveSupport::TestCase
  setup do
    @instrument = instruments(:petr4_bvmf)
    @quoted_at = Time.utc(2026, 8, 26, 15)
    travel_to Time.utc(2026, 8, 26, 15, 0, 5)
  end

  test "supports B3 instruments and returns the application price" do
    client = FakeClient.new(
      quote: MarketData::YahooFinance::Quote.new(
        symbol: "PETR4.SA",
        unit_price: BigDecimal("32.45678901"),
        currency: "BRL",
        quoted_at: @quoted_at
      )
    )
    provider = MarketPrice::Providers::YahooFinance.new(client:)

    current_market_price = provider.fetch(instrument: @instrument)

    assert provider.supports?(instrument: @instrument)
    assert_not provider.supports?(instrument: instruments(:voo_arcx))
    assert_equal "PETR4.SA", client.identifiers.sole.value
    assert_equal BigDecimal("32.45678901"), current_market_price.unit_price
    assert_equal "BRL", current_market_price.currency
    assert_equal "yahoo_finance", current_market_price.provider
    assert_equal @quoted_at, current_market_price.quoted_at
    assert_equal Time.current, current_market_price.fetched_at
  end

  test "rejects a quote in a different currency" do
    provider = MarketPrice::Providers::YahooFinance.new(
      client: FakeClient.new(
        quote: MarketData::YahooFinance::Quote.new(
          symbol: "PETR4.SA",
          unit_price: BigDecimal("32.45"),
          currency: "USD",
          quoted_at: @quoted_at
        )
      )
    )

    assert_raises(MarketPrice::CurrencyMismatch) do
      provider.fetch(instrument: @instrument)
    end
  end

  test "normalizes library errors into an application provider failure" do
    provider = MarketPrice::Providers::YahooFinance.new(
      client: FakeClient.new(error: MarketData::YahooFinance::RateLimited.new(status: 429))
    )

    error = assert_raises(MarketPrice::ProviderFailure) do
      provider.fetch(instrument: @instrument)
    end

    assert_equal "yahoo_finance", error.provider_identifier
    assert_instance_of MarketData::YahooFinance::RateLimited, error.cause
  end

  private

  FakeClient = Data.define(:result, :error, :identifiers) do
    def initialize(quote: nil, error: nil, identifiers: [])
      super(result: quote, error:, identifiers:)
    end

    def quote(identifier)
      identifiers << identifier
      raise error if error

      result
    end
  end
end
