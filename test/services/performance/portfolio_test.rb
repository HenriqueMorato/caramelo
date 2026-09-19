require "test_helper"

class Performance::PortfolioTest < ActiveSupport::TestCase
  setup do
    @date = Date.new(2026, 8, 28)
    @provider = "test_provider"
    @exchange_rate_service = HistoricalExchangeRate::Service.new(provider: Struct.new(:identifier).new(@provider))
    CorporateAction.where(user: User.owner).delete_all
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

  test "reconciles exact portfolio totals with independently calculated instruments including income" do
    first = create_instrument(ticker: "RECONE", currency: "BRL")
    second = create_instrument(ticker: "RECTWO", currency: "BRL")
    [ first, second ].each_with_index do |instrument, index|
      create_trade(instrument:, quantity: index + 1, unit_price: "10")
      create_daily_close(instrument:, close_price: (12 + index).to_s)
      create_corporate_action(
        instrument:, gross_amount_cents: 100 * (index + 1),
        withholding_tax_cents: 0, net_amount_cents: 100 * (index + 1)
      )
    end

    portfolio = portfolio_for
    instruments = [ first, second ].map do |instrument|
      Performance::Portfolio.for(
        valuation_date: @date, owner: User.owner, instrument:,
        exchange_rate_service: @exchange_rate_service,
        daily_closing_price_provider: @provider
      ).position_results.sole
    end

    %i[market_value_amount realized_gain_amount unrealized_gain_amount investment_income_amount].each do |amount|
      assert_equal portfolio.public_send(amount), instruments.sum { |result| result.public_send(amount) }
    end
  end

  test "can calculate a single instrument without loading other portfolio positions" do
    selected = create_instrument(ticker: "SELECTED", currency: "BRL")
    other = create_instrument(ticker: "OTHER", currency: "BRL")
    create_trade(instrument: selected, quantity: 2, unit_price: "10")
    create_trade(instrument: other, quantity: 3, unit_price: "20")
    create_daily_close(instrument: selected, close_price: "12")

    result = Performance::Portfolio.for(
      valuation_date: @date, instrument: selected,
      exchange_rate_service: @exchange_rate_service, daily_closing_price_provider: @provider
    )

    assert result.available?
    assert_equal [ selected ], result.position_results.map(&:instrument)
    assert_equal BigDecimal("24"), result.market_value_amount
  end

  test "groups a supplied trade collection when no instrument is selected" do
    instrument = create_instrument(ticker: "SUPPLIED", currency: "BRL")
    trade = create_trade(instrument:, quantity: 2, unit_price: "10")
    create_daily_close(instrument:, close_price: "12")

    result = Performance::Portfolio.for(
      valuation_date: @date, trades: [ trade ],
      exchange_rate_service: @exchange_rate_service, daily_closing_price_provider: @provider
    )

    assert_equal [ instrument ], result.position_results.map(&:instrument)
  end

  test "returns an empty result when supplied trades do not match the instrument" do
    instrument = create_instrument(ticker: "EMPTY", currency: "BRL")
    other = create_instrument(ticker: "OTHER", currency: "BRL")
    trade = create_trade(instrument: other, quantity: 2, unit_price: "10")

    result = Performance::Portfolio.for(
      valuation_date: @date, instrument:, trades: [ trade ],
      exchange_rate_service: @exchange_rate_service, daily_closing_price_provider: @provider
    )

    assert_predicate result, :empty?
  end

  test "returns an empty result for an instrument without persisted trades" do
    instrument = create_instrument(ticker: "NO_TRADES", currency: "BRL")

    result = Performance::Portfolio.for(
      valuation_date: @date, instrument:,
      exchange_rate_service: @exchange_rate_service, daily_closing_price_provider: @provider
    )

    assert_predicate result, :empty?
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
    assert_equal [ [ trade_date, 100 ], [ @date, -84 ] ], result.cash_flows.map { |cash_flow| [ cash_flow.occurred_on, cash_flow.amount ] }
  end

  test "counts confirmed net income as return without changing trade cash flow or basis" do
    instrument = create_instrument(ticker: "INCOME", currency: "BRL")
    create_trade(instrument:, traded_on: @date - 2, quantity: 2, unit_price: "10")
    create_daily_close(instrument:, close_price: "10")
    action = create_corporate_action(
      instrument:, paid_on: @date - 1, ex_date: @date - 2, gross_amount_cents: 1_000,
      withholding_tax_cents: 150, net_amount_cents: 850
    )

    result = portfolio_for
    position = result.position_results.sole

    assert_equal BigDecimal("20"), result.net_cash_flow_amount
    assert_equal BigDecimal("8.5"), result.investment_income_amount
    assert_equal Money.from_amount(8.5, "BRL"), result.investment_income
    assert_equal BigDecimal("20"), position.reporting_cost_basis_amount
    assert_equal BigDecimal("8.5"), position.total_gain_amount
    assert_equal BigDecimal("0.425"), position.return_ratio
    assert_equal [
      [ @date - 2, BigDecimal("20"), :trade ],
      [ action.ex_date, BigDecimal("-8.5"), :corporate_action ]
    ], result.cash_flows.map { |flow| [ flow.occurred_on, flow.amount, flow.source ] }
  end

  test "converts income with ex-date FX rather than payment-date or valuation-date FX" do
    instrument = create_instrument(ticker: "INCOMEFX", currency: "USD")
    create_trade(
      instrument:, traded_on: @date - 3, quantity: 1, unit_price: "10",
      settlement_exchange_rate: "5"
    )
    create_corporate_action(
      instrument:, paid_on: @date - 2, ex_date: @date - 3, gross_amount_cents: 200,
      withholding_tax_cents: 0, net_amount_cents: 200, currency: "USD"
    )
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5", rate_date: @date - 3)
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5.5", rate_date: @date - 2)
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "6", rate_date: @date)
    create_daily_close(instrument:, close_price: "10")

    result = portfolio_for

    assert_equal BigDecimal("10"), result.investment_income_amount
    assert_equal BigDecimal("60"), result.market_value_amount
  end

  test "is unavailable rather than dropping income whose historical FX is missing" do
    instrument = create_instrument(ticker: "INCOMEGAP", currency: "USD")
    create_trade(instrument:, traded_on: @date - 10, settlement_exchange_rate: "5")
    create_corporate_action(
      instrument:, paid_on: @date - 7,
      gross_amount_cents: 200, withholding_tax_cents: 0, net_amount_cents: 200, currency: "USD"
    )
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "6", rate_date: @date)
    create_daily_close(instrument:, close_price: "10")

    assert_predicate portfolio_for, :missing?
  end

  test "ignores unconfirmed and not-yet-effective income" do
    instrument = create_instrument(ticker: "INCOMESTATE", currency: "BRL")
    create_trade(instrument:, quantity: 1, unit_price: "10")
    create_daily_close(instrument:, close_price: "10")
    create_corporate_action(
      instrument:, status: :pending, gross_amount_cents: 100,
      withholding_tax_cents: 0, net_amount_cents: 100
    )
    create_corporate_action(
      instrument:, paid_on: @date + 2, gross_amount_cents: 200,
      withholding_tax_cents: 0, net_amount_cents: 200
    )

    result = portfolio_for

    assert_equal BigDecimal("0"), result.investment_income_amount
    assert_equal [ :trade ], result.cash_flows.map(&:source)
  end

  test "recognizes income on its ex-date before the later payment date" do
    instrument = create_instrument(ticker: "INCOMEEX", currency: "BRL")
    create_trade(instrument:, traded_on: @date - 2, quantity: 1, unit_price: "10")
    create_daily_close(instrument:, close_price: "9")
    action = create_corporate_action(
      instrument:, paid_on: @date + 2, ex_date: @date - 1,
      gross_amount_cents: 100, withholding_tax_cents: 0, net_amount_cents: 100
    )

    result = portfolio_for

    assert_equal BigDecimal("1"), result.investment_income_amount
    assert_equal [ action.ex_date ], result.cash_flows.select { |flow| flow.source == :corporate_action }
      .map(&:occurred_on)
  end

  test "uses the actual paid rate for reporting basis and daily FX for market value" do
    instrument = create_instrument(ticker: "PAID", currency: "USD")
    create_trade(
      instrument:, quantity: 2, unit_price: "200", settlement_exchange_rate: "5.25"
    )
    create_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5.1", rate_date: @date)
    create_daily_close(instrument:, close_price: "220")

    result = portfolio_for
    position = result.position_results.sole

    assert_equal BigDecimal("2100"), position.reporting_cost_basis_amount
    assert_equal BigDecimal("2244"), position.market_value_amount
    assert_equal BigDecimal("144"), position.unrealized_gain_amount
    assert_equal BigDecimal("144") / BigDecimal("2100"), position.return_ratio
  end

  test "reports foreign instrument performance natively without using paid or historical FX" do
    instrument = create_instrument(ticker: "NATIVE", currency: "USD")
    trade = create_trade(
      instrument:, quantity: 2, unit_price: "200", settlement_exchange_rate: "5.25"
    )
    create_daily_close(instrument:, close_price: "220")

    result = Performance::Portfolio.for(
      valuation_date: @date, instrument:, trades: [ trade ], reporting_currency: "USD",
      exchange_rate_service: @exchange_rate_service, daily_closing_price_provider: @provider
    )
    position = result.position_results.sole

    assert_equal BigDecimal("400"), position.reporting_cost_basis_amount
    assert_equal BigDecimal("440"), position.market_value_amount
    assert_equal BigDecimal("40"), position.unrealized_gain_amount
    assert_equal BigDecimal("0.1"), position.return_ratio
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
    assert_nil result.position_results.first.total_gain_amount
    assert_nil result.position_results.first.return_ratio
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
    assert_nil position_result.with(invested_amount: BigDecimal("0")).return_ratio
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

  def create_trade(instrument:, side: :buy, traded_on: @date, quantity: 1, unit_price: "1", fees_cents: 0,
    settlement_exchange_rate: nil)
    User.owner.trades.create!(
      instrument:, side:, traded_on:, quantity:, unit_price:, fees_cents:, currency: instrument.currency,
      settlement_exchange_rate:
    )
  end

  def create_corporate_action(instrument:, paid_on: @date, ex_date: nil, status: :confirmed,
    gross_amount_cents:, withholding_tax_cents:, net_amount_cents:,
    currency: instrument.currency)
    CorporateAction.create!(
      user: User.owner, instrument:, kind: :dividend, status:,
      paid_on:, ex_date:, gross_amount_cents:, withholding_tax_cents:, net_amount_cents:,
      currency:, source: "manual"
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
