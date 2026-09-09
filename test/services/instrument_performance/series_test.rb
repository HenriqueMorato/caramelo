require "test_helper"

class InstrumentPerformance::SeriesTest < ActiveSupport::TestCase
  setup do
    @user = users(:owner)
    @from = Date.new(2026, 8, 24)
    @to = Date.new(2026, 8, 28)
    Trade.where(user: @user).delete_all
  end

  test "materializes native and reporting views and matches direct Modified Dietz calculation" do
    instrument = create_instrument(ticker: "FXSER", currency: "USD")
    create_trade(
      instrument:, date: @from, side: :buy, quantity: "2", unit_price: "10",
      fees_cents: 100, settlement_exchange_rate: "4.5"
    )
    create_trade(
      instrument:, date: @from + 1, side: :buy, quantity: "1.5", unit_price: "12",
      fees_cents: 50
    )
    create_trade(
      instrument:, date: @from + 2, side: :sell, quantity: "1", unit_price: "16",
      fees_cents: 25
    )
    (@from..@to).each_with_index do |date, offset|
      create_close(instrument:, date:, price: (16 + offset).to_s)
      create_rate(date:, rate: (BigDecimal("5") + BigDecimal("0.1") * offset).to_s("F"))
    end

    Performance::ObservationBuilder.new(
      user: @user, instrument:, reporting_currency: "USD"
    ).call(from: @from, to: @to)
    Performance::ObservationBuilder.new(
      user: @user, instrument:, reporting_currency: "BRL"
    ).call(from: @from, to: @to)

    native = Performance::Series.for(
      from: @from, to: @to, user: @user, instrument:, reporting_currency: "USD"
    )
    reporting = Performance::Series.for(
      from: @from, to: @to, user: @user, instrument:, reporting_currency: "BRL"
    )
    direct_period = Performance::Period.for(from: @from, to: @to, owner: @user, instrument:)
    direct_position = direct_period.closing_valuation.position_results.sole
    native_position = Performance::Portfolio.for(
      valuation_date: @to,
      owner: @user,
      instrument:,
      reporting_currency: "USD"
    ).position_results.sole
    reporting_record = InstrumentPerformanceObservation.find_by!(
      user: @user, instrument:, reporting_currency: "BRL", observed_on: @to
    )

    assert_predicate native, :available?
    assert_predicate reporting, :available?
    assert_equal BigDecimal("50"), native.observations.last.market_value_amount
    assert_equal native_position.reporting_cost_basis_amount, native.observations.last.invested_amount
    assert_equal direct_position.market_value_amount, reporting_record.market_value_amount
    assert_equal direct_position.reporting_cost_basis_amount, reporting_record.cost_basis_amount
    assert_equal direct_position.realized_gain_amount, reporting_record.realized_gain_amount
    assert_equal direct_position.unrealized_gain_amount, reporting_record.unrealized_gain_amount
    assert_equal direct_position.net_cash_flow_amount, reporting_record.net_cash_flow_amount
    assert_equal direct_position.reporting_cost_basis_amount, reporting.observations.last.invested_amount
    assert_equal direct_period.gain_loss_amount, reporting.observations.last.gain_loss_amount
    assert_equal direct_period.return_ratio, reporting.observations.last.return_ratio
    assert_equal BigDecimal("0"), reporting.observations.first.return_ratio
  end

  test "preserves realized gain through closure and reopening" do
    instrument = create_instrument(ticker: "REOPEN", currency: "BRL")
    create_trade(instrument:, date: @from, side: :buy, quantity: "2", unit_price: "10", fees_cents: 100)
    create_trade(instrument:, date: @from + 1, side: :sell, quantity: "2", unit_price: "15", fees_cents: 100)
    create_trade(instrument:, date: @from + 2, side: :buy, quantity: "1", unit_price: "12", fees_cents: 0)
    create_close(instrument:, date: @from, price: "11")
    create_close(instrument:, date: @from + 2, price: "13")

    Performance::ObservationBuilder.new(
      user: @user, instrument:, reporting_currency: "BRL"
    ).call(from: @from, to: @from + 2)

    records = InstrumentPerformanceObservation.where(user: @user, instrument:).chronological.to_a
    closed = records.second
    reopened = records.third
    assert_predicate closed, :available?
    assert_equal BigDecimal("0"), closed.market_value_amount
    assert_equal BigDecimal("0"), closed.cost_basis_amount
    assert_equal BigDecimal("8"), closed.realized_gain_amount
    assert_equal BigDecimal("13"), reopened.market_value_amount
    assert_equal BigDecimal("12"), reopened.cost_basis_amount
    assert_equal BigDecimal("8"), reopened.realized_gain_amount
    assert_equal BigDecimal("1"), reopened.unrealized_gain_amount
  end

  test "keeps calendar rows without synthesizing market data" do
    friday = Date.new(2026, 8, 28)
    sunday = friday + 2
    instrument = create_instrument(ticker: "WKDSER", currency: "BRL")
    create_trade(instrument:, date: friday, side: :buy, quantity: "2", unit_price: "10", fees_cents: 0)
    create_close(instrument:, date: friday, price: "12")

    Performance::ObservationBuilder.new(
      user: @user, instrument:, reporting_currency: "BRL"
    ).call(from: friday, to: sunday)

    records = InstrumentPerformanceObservation.where(user: @user, instrument:).chronological
    assert_equal [ friday, friday + 1, sunday ], records.pluck(:observed_on)
    assert records.all?(&:available?)
    assert_equal [ BigDecimal("24") ], records.map(&:market_value_amount).uniq
    assert_equal [ friday ], instrument.daily_closing_prices.pluck(:trading_date)
  end

  private

  def create_instrument(ticker:, currency:)
    Instrument.create!(ticker:, exchange: "XNAS", name: "#{ticker} instrument", currency:)
  end

  def create_trade(instrument:, date:, side:, quantity:, unit_price:, fees_cents:, settlement_exchange_rate: nil)
    @user.trades.create!(
      instrument:, traded_on: date, side:, quantity:, unit_price:, fees_cents:,
      currency: instrument.currency, settlement_exchange_rate:
    )
  end

  def create_close(instrument:, date:, price:)
    DailyClosingPrice.create!(
      instrument:, trading_date: date, close_price: price, currency: instrument.currency,
      provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier, observed_at: Time.current
    )
  end

  def create_rate(date:, rate:)
    HistoricalExchangeRate.create!(
      base_currency: "USD", quote_currency: "BRL", rate_date: date, rate:,
      provider: MarketData::YahooFinance::FX_CONFIGURATION.identifier,
      observed_at: Time.current, fetched_at: Time.current
    )
  end
end
