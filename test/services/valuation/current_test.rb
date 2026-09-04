require "test_helper"

class Valuation::CurrentTest < ActiveSupport::TestCase
  test "uses the owner preference and skips FX when it matches the instrument" do
    users(:owner).update!(reporting_currency: "USD")
    instrument = instruments(:voo_arcx)
    position = Position.for(instrument:)
    market_price = market_price_presenter(instrument:, unit_price: "100")
    exchange_rate_service = FakeExchangeRateService.new(lookup: rate_lookup(rate: "5"))

    result = Valuation::Current.for(position:, market_price:, exchange_rate_service:)

    assert_equal Money.from_amount(250, "USD"), result.market_value
    assert_predicate result, :same_currency?
    assert_empty exchange_rate_service.requests
  end

  test "requests the selected currency and preserves missing FX instead of relabeling a value" do
    users(:owner).update!(reporting_currency: "EUR")
    instrument = instruments(:voo_arcx)
    position = Position.for(instrument:)
    market_price = market_price_presenter(instrument:, unit_price: "100")
    exchange_rate_service = FakeExchangeRateService.new(
      lookup: ExchangeRateCache::Lookup.new(exchange_rate: nil, status: :missing)
    )

    result = Valuation::Current.for(position:, market_price:, exchange_rate_service:)

    assert_equal [ [ "USD", "EUR" ] ], exchange_rate_service.requests
    assert_predicate result, :missing?
    assert_nil result.market_value
  end

  test "converts a foreign market value into the reporting currency" do
    instrument = instruments(:voo_arcx)
    position = Position.for(instrument:)
    market_price = market_price_presenter(instrument:, unit_price: "100")
    exchange_rate_service = FakeExchangeRateService.new(lookup: rate_lookup(rate: "5"))

    result = Valuation::Current.for(position:, market_price:, exchange_rate_service:)

    assert_equal Money.from_amount(1_250, "BRL"), result.market_value
    assert_predicate result, :available?
    assert_equal [ [ "USD", "BRL" ] ], exchange_rate_service.requests
  end

  test "does not request FX for a same-currency market value" do
    instrument = Instrument.create!(ticker: "BRLVAL", exchange: "BVMF", name: "Brazilian value", currency: "BRL")
    User.owner.trades.create!(instrument:, side: :buy, traded_on: Date.current, quantity: 2, unit_price: 10, fees_cents: 0, currency: "BRL")
    position = Position.for(instrument:)
    market_price = market_price_presenter(instrument:, unit_price: "32.45678901")
    exchange_rate_service = FakeExchangeRateService.new(lookup: rate_lookup(rate: "5"))

    result = Valuation::Current.for(position:, market_price:, exchange_rate_service:)

    assert_equal Money.from_amount(BigDecimal("64.91357802"), "BRL"), result.market_value
    assert_predicate result, :same_currency?
    assert_empty exchange_rate_service.requests
  end

  test "keeps a converted value visible when the FX rate is stale" do
    instrument = instruments(:voo_arcx)
    position = Position.for(instrument:)
    market_price = market_price_presenter(instrument:, unit_price: "100")
    exchange_rate_service = FakeExchangeRateService.new(lookup: rate_lookup(rate: "5", stale: true))

    result = Valuation::Current.for(position:, market_price:, exchange_rate_service:)

    assert_equal Money.from_amount(1_250, "BRL"), result.market_value
    assert_predicate result, :stale?
  end

  test "returns an unavailable result when the FX rate is missing" do
    instrument = instruments(:voo_arcx)
    position = Position.for(instrument:)
    market_price = market_price_presenter(instrument:, unit_price: "100")
    exchange_rate_service = FakeExchangeRateService.new(lookup: ExchangeRateCache::Lookup.new(exchange_rate: nil, status: :missing))

    result = Valuation::Current.for(position:, market_price:, exchange_rate_service:)

    assert_predicate result, :missing?
    assert_not_predicate result, :available?
    assert_nil result.market_value
  end

  private

  FakeExchangeRateService = Struct.new(:lookup, :requests) do
    def initialize(lookup:)
      super(lookup, [])
    end

    def read(base_currency:, quote_currency:)
      requests << [ base_currency, quote_currency ]
      lookup
    end
  end

  def market_price_presenter(instrument:, unit_price:)
    quote = CurrentMarketPrice.new(
      unit_price:, currency: instrument.currency, provider: "yahoo_finance",
      quoted_at: Time.current, fetched_at: Time.current
    )
    lookup = CurrentMarketPriceCache::Lookup.new(current_market_price: quote, status: :fresh)
    MarketPrice::Presenter.new(instrument:, lookup:)
  end

  def rate_lookup(rate:, stale: false)
    status = stale ? :stale : :fresh
    ExchangeRateCache::Lookup.new(
      exchange_rate: ExchangeRate::Rate.new(
        base_currency: "USD", quote_currency: "BRL", rate: BigDecimal(rate),
        observed_at: Time.current, fetched_at: stale ? 31.minutes.ago : Time.current,
        provider: "yahoo_finance_fx"
      ),
      status:
    )
  end
end
