require "test_helper"

class Performance::PortfolioTest < ActiveSupport::TestCase
  setup do
    @date = Date.new(2026, 8, 28)
    @provider = "test_provider"
    @exchange_rate_service = HistoricalExchangeRate::Service.new(provider: Struct.new(:identifier).new(@provider))
    Trade.where(user: User.owner).delete_all
  end

  test "aggregates exact multi-currency market values and unrealized gains" do
    brl_instrument = create_instrument(ticker: "BRL1", currency: "BRL")
    usd_instrument = create_instrument(ticker: "USD1", currency: "USD")
    create_trade(instrument: brl_instrument, quantity: 2, unit_price: "10", fees_cents: 100)
    create_trade(instrument: usd_instrument, quantity: 3, unit_price: "10")
    create_daily_close(instrument: brl_instrument, close_price: "15")
    create_daily_close(instrument: usd_instrument, close_price: "12")
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5", rate_date: @date)

    result = portfolio_for

    assert result.available?
    assert_equal BigDecimal("210"), result.market_value_amount
    assert_equal BigDecimal("39"), result.unrealized_gain_amount
    assert_equal BigDecimal("171"), result.net_cash_flow_amount
    assert_equal Money.from_amount(210, "BRL"), result.market_value
    assert_equal [ brl_instrument, usd_instrument ], result.position_results.map(&:instrument)
    assert_equal @date, result.market_data_as_of
  end

  test "keeps realized and unrealized gains separate after a partial foreign sale" do
    instrument = create_instrument(ticker: "PART", currency: "USD")
    trade_date = @date - 1
    create_trade(instrument:, traded_on: trade_date, quantity: 2, unit_price: "10")
    create_trade(instrument:, side: :sell, quantity: 1, unit_price: "15", fees_cents: 100)
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5", rate_date: trade_date)
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "6", rate_date: @date)
    create_daily_close(instrument:, close_price: "20")

    result = portfolio_for
    position_result = result.position_results.first

    assert result.available?
    assert_equal BigDecimal("34"), result.realized_gain_amount
    assert_equal BigDecimal("70"), result.unrealized_gain_amount
    assert_equal BigDecimal("104"), result.realized_gain_amount + result.unrealized_gain_amount
    assert_equal BigDecimal("16"), result.net_cash_flow_amount
    assert_equal BigDecimal("120"), result.market_value_amount
    assert_equal BigDecimal("50"), position_result.reporting_cost_basis_amount
    assert_equal [ [ trade_date, 100 ], [ @date, -84 ] ], result.cash_flows.map { |cash_flow| [ cash_flow.traded_on, cash_flow.amount ] }
  end

  test "preserves fractional quantities and precise prices until presentation" do
    instrument = create_instrument(ticker: "FRAC", currency: "USD")
    create_trade(instrument:, quantity: "0.00000001", unit_price: "98765.43218765", fees_cents: 1)
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5.12345678", rate_date: @date)
    create_daily_close(instrument:, close_price: "100000.12345678")

    result = portfolio_for

    expected = BigDecimal("0.00000001") * BigDecimal("100000.12345678") * BigDecimal("5.12345678")
    assert_equal expected, result.market_value_amount
    assert_equal Money.from_amount(expected, "BRL"), result.market_value
  end

  test "is unavailable when a needed transaction-date exchange rate is missing" do
    instrument = create_instrument(ticker: "MISS", currency: "USD")
    create_trade(instrument:, traded_on: @date - 1)
    create_daily_close(instrument:, close_price: "10")
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5", rate_date: @date)

    result = portfolio_for

    assert result.missing?
    assert_not result.available?
    assert result.position_results.first.missing?
    assert_not result.position_results.first.available?
    assert_nil result.market_value
  end

  test "uses the latest persisted exchange rate when the valuation date has none" do
    instrument = create_instrument(ticker: "NOFX", currency: "USD")
    create_trade(instrument:, traded_on: @date - 1)
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5", rate_date: @date - 1)
    create_daily_close(instrument:, close_price: "10")

    result = portfolio_for

    assert result.available?
    assert_equal BigDecimal("10"), result.position_results.first.daily_closing_price.close_price
    assert_equal @date - 1, result.position_results.first.exchange_rate_lookup.exchange_rate.rate_date
  end

  test "exposes separate market price and FX observation dates" do
    instrument = create_instrument(ticker: "DATES", currency: "USD")
    create_trade(instrument:)
    create_daily_close(instrument:, close_price: "10")
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5", rate_date: @date - 1)

    result = portfolio_for
    position_result = result.position_results.first

    assert_equal @date, position_result.market_price_as_of
    assert_equal @date - 1, position_result.exchange_rate_as_of
    assert_equal @date, result.market_price_as_of
    assert_equal @date - 1, result.exchange_rate_as_of
    assert_equal @date, result.market_data_as_of
  end

  test "does not report an FX observation date for same-currency positions" do
    instrument = create_instrument(ticker: "SAME", currency: "BRL")
    create_trade(instrument:)
    create_daily_close(instrument:, close_price: "10")

    result = portfolio_for

    assert_equal @date, result.market_price_as_of
    assert_nil result.exchange_rate_as_of
  end

  test "is unavailable when valuation FX is missing after trade FX was available" do
    instrument = create_instrument(ticker: "VALUATIONFX", currency: "USD")
    create_trade(instrument:, traded_on: @date - 1)
    create_daily_close(instrument:, close_price: "10")
    trade_date = @date - 1
    available_lookup = Lookup.new(available: true, exchange_rate: ResolvedRate.new(rate: BigDecimal("5")))
    missing_lookup = Lookup.new(available: false, exchange_rate: nil)
    exchange_rate_service = Object.new
    exchange_rate_service.define_singleton_method(:read) do |rate_date:, **|
      rate_date == trade_date ? available_lookup : missing_lookup
    end

    result = Performance::Portfolio.for(
      valuation_date: @date, exchange_rate_service:, daily_closing_price_provider: @provider
    )

    assert result.missing?
    assert_equal missing_lookup, result.position_results.first.exchange_rate_lookup
    assert_nil result.position_results.first.exchange_rate_as_of
  end

  test "is unavailable when a needed closing price is missing" do
    instrument = create_instrument(ticker: "NOCLOSE", currency: "BRL")
    create_trade(instrument:)

    result = portfolio_for

    assert result.missing?
    assert result.position_results.first.missing?
    assert_nil result.position_results.first.daily_closing_price
  end

  test "uses a recent persisted market observation for a weekend valuation" do
    instrument = create_instrument(ticker: "WKND", currency: "USD")
    create_trade(instrument:, quantity: 2, unit_price: "10")
    create_daily_close(instrument:, close_price: "12")
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5", rate_date: @date)

    result = Performance::Portfolio.for(
      valuation_date: @date + 1, exchange_rate_service: @exchange_rate_service,
      daily_closing_price_provider: @provider
    )

    assert result.available?
    assert_equal @date, result.position_results.first.daily_closing_price.trading_date
    assert_equal BigDecimal("120"), result.market_value_amount
  end

  test "does not use a market observation older than seven days" do
    instrument = create_instrument(ticker: "STALE", currency: "BRL")
    create_trade(instrument:)
    DailyClosingPrice.create!(
      instrument:, trading_date: @date - 8, close_price: "10", currency: "BRL", provider: @provider, observed_at: Time.current
    )

    assert portfolio_for.missing?
  end

  test "reports an empty portfolio with zero values" do
    result = portfolio_for

    assert result.empty?
    assert result.available?
    assert_equal Money.new(0, "BRL"), result.market_value
    assert_empty result.position_results
    assert_nil result.market_data_as_of
  end

  test "retains realized gain for a closed position without requiring a closing price" do
    instrument = create_instrument(ticker: "CLOSE", currency: "BRL")
    create_trade(instrument:, quantity: 2, unit_price: "10")
    create_trade(instrument:, side: :sell, quantity: 2, unit_price: "15", fees_cents: 100)

    result = portfolio_for
    position_result = result.position_results.first

    assert result.available?
    assert position_result.closed?
    assert position_result.available?
    assert_equal BigDecimal("9"), result.realized_gain_amount
    assert_equal BigDecimal("0"), result.unrealized_gain_amount
    assert_equal Money.new(0, "BRL"), result.market_value
    assert_nil result.market_data_as_of
  end

  test "rejects a historical sale that would make a position negative" do
    instrument = create_instrument(ticker: "SHORT", currency: "BRL")
    create_trade(instrument:, side: :sell)

    assert_raises(Position::InvalidLongOnlyData) { portfolio_for }
  end

  test "rejects a future valuation date" do
    assert_raises(ArgumentError) do
      Performance::Portfolio.for(valuation_date: Date.current + 1)
    end
  end

  private

  Lookup = Data.define(:available, :exchange_rate) do
    def available? = available
    def same_currency? = false
  end

  ResolvedRate = Data.define(:rate)

  def portfolio_for
    Performance::Portfolio.for(
      valuation_date: @date, exchange_rate_service: @exchange_rate_service,
      daily_closing_price_provider: @provider
    )
  end

  def create_instrument(ticker:, currency:)
    Instrument.create!(ticker:, exchange: "XNAS", name: "#{ticker} instrument", currency:)
  end

  def create_trade(instrument:, side: :buy, traded_on: @date, quantity: 1, unit_price: "1", fees_cents: 0)
    User.owner.trades.create!(
      instrument:, side:, traded_on:, quantity:, unit_price:, fees_cents:, currency: instrument.currency
    )
  end

  def create_daily_close(instrument:, close_price:)
    DailyClosingPrice.create!(
      instrument:, trading_date: @date, close_price:, currency: instrument.currency,
      provider: @provider, observed_at: Time.current
    )
  end

  def create_exchange_rate(base_currency:, quote_currency:, rate:, rate_date:)
    HistoricalExchangeRate.create!(
      base_currency:, quote_currency:, rate_date:, rate:, provider: @provider,
      observed_at: Time.current, fetched_at: Time.current
    )
  end
end
