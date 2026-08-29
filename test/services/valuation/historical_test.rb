require "test_helper"

class Valuation::HistoricalTest < ActiveSupport::TestCase
  setup do
    @date = Date.new(2026, 8, 28)
    @provider = "test_provider"
    @exchange_rate_service = HistoricalExchangeRate::Service.new(provider: Struct.new(:identifier).new(@provider))
  end

  test "values a reporting-currency position from its exact daily close" do
    instrument = create_instrument(currency: "BRL")
    create_trade(instrument:, quantity: "1.23456789")
    create_daily_close(instrument:, close_price: "12.34567891")

    result = valuation_for(instrument:)

    assert result.available?
    assert result.same_currency?
    assert_equal BigDecimal("15.2415787625361999"), result.native_market_value_amount
    assert_equal result.native_market_value_amount, result.market_value_amount
    assert_equal Money.from_amount(result.market_value_amount, "BRL"), result.market_value
  end

  test "converts a foreign position with the persisted rate for the same date" do
    instrument = create_instrument(currency: "USD")
    create_trade(instrument:, quantity: "1.23456789")
    create_daily_close(instrument:, close_price: "12.34567891")
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5.67890123")

    result = valuation_for(instrument:)

    assert result.available?
    assert_equal BigDecimal("15.2415787625361999"), result.native_market_value_amount
    assert_equal BigDecimal("86.555420381708703531635877"), result.market_value_amount
    assert_equal Money.from_amount(result.market_value_amount, "BRL"), result.market_value
  end

  test "uses Friday's persisted close and rate for a weekend valuation" do
    instrument = create_instrument(currency: "USD")
    create_trade(instrument:, quantity: 2)
    create_daily_close(instrument:, close_price: "10")
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5")

    result = Valuation::Historical.for(
      position: Position.for(instrument:, as_of: @date), valuation_date: @date + 1,
      exchange_rate_service: @exchange_rate_service, daily_closing_price_provider: @provider
    )

    assert result.available?
    assert_equal @date, result.daily_closing_price.trading_date
    assert_equal @date, result.exchange_rate_lookup.exchange_rate.rate_date
    assert_equal BigDecimal("100"), result.market_value_amount
  end

  test "uses an inverse persisted exchange rate" do
    instrument = create_instrument(currency: "USD")
    create_trade(instrument:, quantity: 2)
    create_daily_close(instrument:, close_price: "10")
    create_exchange_rate(base_currency: "BRL", quote_currency: "USD", rate: "0.2")

    result = valuation_for(instrument:)

    assert result.available?
    assert_equal BigDecimal("100"), result.market_value_amount
    assert result.exchange_rate_lookup.inverted
  end

  test "is unavailable when the daily close is missing" do
    instrument = create_instrument(currency: "USD")
    create_trade(instrument:)

    result = valuation_for(instrument:)

    assert result.missing?
    assert_nil result.market_value
    assert_nil result.daily_closing_price
    assert_nil result.exchange_rate_lookup
  end

  test "is unavailable when a required exchange rate is missing" do
    instrument = create_instrument(currency: "USD")
    create_trade(instrument:)
    create_daily_close(instrument:, close_price: "10")

    result = valuation_for(instrument:)

    assert result.missing?
    assert_equal BigDecimal("10"), result.daily_closing_price.close_price
    assert result.exchange_rate_lookup.missing?
  end

  test "values a closed position at zero without requiring a market observation" do
    instrument = create_instrument(currency: "USD")
    create_trade(instrument:, side: :buy)
    create_trade(instrument:, side: :sell, traded_on: @date)

    result = valuation_for(instrument:)

    assert result.available?
    assert result.closed?
    assert_equal BigDecimal("0"), result.market_value_amount
    assert_equal Money.new(0, "BRL"), result.market_value
  end

  test "rejects a future valuation date" do
    instrument = create_instrument(currency: "BRL")

    assert_raises(ArgumentError) do
      Valuation::Historical.for(position: Position.for(instrument:), valuation_date: Date.current + 1)
    end
  end

  private

  def valuation_for(instrument:)
    Valuation::Historical.for(
      position: Position.for(instrument:, as_of: @date), valuation_date: @date,
      exchange_rate_service: @exchange_rate_service, daily_closing_price_provider: @provider
    )
  end

  def create_instrument(currency:)
    Instrument.create!(ticker: "TEST#{Instrument.count}", exchange: "XNAS", name: "Test instrument", currency:)
  end

  def create_trade(instrument:, side: :buy, quantity: 1, traded_on: @date)
    User.owner.trades.create!(
      instrument:, side:, traded_on:, quantity:, unit_price: "1", fees_cents: 0, currency: instrument.currency
    )
  end

  def create_daily_close(instrument:, close_price:)
    DailyClosingPrice.create!(
      instrument:, trading_date: @date, close_price:, currency: instrument.currency,
      provider: @provider, observed_at: Time.current
    )
  end

  def create_exchange_rate(base_currency:, quote_currency:, rate:)
    HistoricalExchangeRate.create!(
      base_currency:, quote_currency:, rate_date: @date, rate:, provider: @provider,
      observed_at: Time.current, fetched_at: Time.current
    )
  end
end
