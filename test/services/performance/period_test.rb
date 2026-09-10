require "test_helper"

class Performance::PeriodTest < ActiveSupport::TestCase
  setup do
    @from = Date.new(2026, 8, 26)
    @to = Date.new(2026, 8, 28)
  end

  test "calculates a Modified Dietz return with a mid-period purchase" do
    purchase = cash_flow(date: @from + 1, amount: "100")
    period = calculate_period(opening_amount: "100", closing_amount: "220", cash_flows: [ purchase ])

    assert period.available?
    assert_equal BigDecimal("100"), period.net_cash_flow_amount
    assert_equal BigDecimal("20"), period.gain_loss_amount
    assert_equal BigDecimal("0.13333333333333333333333333333333"), period.return_ratio
    assert_equal Money.from_amount(20, "BRL"), period.gain_loss
  end

  test "does not treat end-of-period sale proceeds as investment return" do
    sale = cash_flow(date: @to, amount: "-110")
    period = calculate_period(opening_amount: "100", closing_amount: "0", cash_flows: [ sale ])

    assert_equal BigDecimal("-110"), period.net_cash_flow_amount
    assert_equal BigDecimal("10"), period.gain_loss_amount
    assert_equal BigDecimal("0.1"), period.return_ratio
  end

  test "uses persisted trades, daily closes, and historical exchange rates" do
    Trade.where(user: User.owner).delete_all
    instrument = Instrument.create!(ticker: "PRDI", exchange: "XNAS", name: "Period instrument", currency: "USD")
    create_trade(instrument:, traded_on: @from)
    create_trade(instrument:, traded_on: @to)
    create_daily_close(instrument:, date: @from, close_price: "10")
    create_daily_close(instrument:, date: @to, close_price: "11")
    create_exchange_rate(date: @from, rate: "5")
    create_exchange_rate(date: @to, rate: "5")

    period = Performance::Period.for(from: @from, to: @to, portfolio: configured_portfolio)

    assert period.available?
    assert_equal BigDecimal("50"), period.opening_valuation.market_value_amount
    assert_equal BigDecimal("110"), period.closing_valuation.market_value_amount
    assert_equal BigDecimal("50"), period.net_cash_flow_amount
    assert_equal BigDecimal("10"), period.gain_loss_amount
    assert_equal BigDecimal("0.2"), period.return_ratio
  end

  test "passes an instrument target to both endpoint valuations" do
    instrument = instruments(:voo_arcx)
    portfolio = InstrumentPortfolio.new(
      instrument:,
      valuations: {
        @from => valuation(date: @from, amount: "100"),
        @to => valuation(date: @to, amount: "110")
      }
    )

    period = Performance::Period.for(from: @from, to: @to, portfolio:, instrument:)

    assert_predicate period, :available?
    assert_equal [ @from, @to ], portfolio.dates
  end

  test "is unavailable when either endpoint is unavailable" do
    opening = valuation(date: @from, amount: nil, status: :missing)
    closing = valuation(date: @to, amount: "100")

    period = Performance::Period.for(
      from: @from, to: @to, portfolio: StubPortfolio.new(valuations: { @from => opening, @to => closing })
    )

    assert period.missing?
    assert_not period.available?
    assert_nil period.gain_loss
    assert_nil period.return_ratio
  end

  test "reports an empty period without a return" do
    period = calculate_period(opening_amount: "0", closing_amount: "0", status: :empty)

    assert period.empty?
    assert period.available?
    assert_nil period.return_ratio
  end

  test "does not calculate a return for a same-day period" do
    valuation = valuation(date: @from, amount: "100")
    period = Performance::Period.for(from: @from, to: @from, portfolio: StubPortfolio.new(valuations: { @from => valuation }))

    assert period.available?
    assert_nil period.return_ratio
  end

  test "rejects invalid or future ranges" do
    portfolio = StubPortfolio.new(valuations: {})

    assert_raises(ArgumentError) { Performance::Period.for(from: @to, to: @from, portfolio:) }
    assert_raises(ArgumentError) { Performance::Period.for(from: "2026-08-26", to: @to, portfolio:) }
    assert_raises(ArgumentError) { Performance::Period.for(from: @from, to: Date.current + 1, portfolio:) }
  end

  private

  StubPortfolio = Data.define(:valuations) do
    def for(valuation_date:, owner:)
      valuations.fetch(valuation_date)
    end
  end

  ConfiguredPortfolio = Data.define(:exchange_rate_service, :daily_closing_price_provider) do
    def for(valuation_date:, owner:)
      Performance::Portfolio.for(valuation_date:, owner:, exchange_rate_service:, daily_closing_price_provider:)
    end
  end

  class InstrumentPortfolio
    attr_reader :dates

    def initialize(instrument:, valuations:)
      @instrument = instrument
      @valuations = valuations
      @dates = []
    end

    def for(valuation_date:, owner:, instrument:)
      raise "wrong owner" unless owner == User.owner
      raise "wrong instrument" unless instrument == @instrument

      dates << valuation_date
      @valuations.fetch(valuation_date)
    end
  end

  def calculate_period(opening_amount:, closing_amount:, cash_flows: [], status: :available)
    opening = valuation(date: @from, amount: opening_amount, status:)
    closing = valuation(date: @to, amount: closing_amount, cash_flows:, status:)
    Performance::Period.for(
      from: @from, to: @to, portfolio: StubPortfolio.new(valuations: { @from => opening, @to => closing })
    )
  end

  def valuation(date:, amount:, cash_flows: [], status: :available)
    money = Money.from_amount(BigDecimal(amount), "BRL") if amount
    Performance::Portfolio::Result.new(
      valuation_date: date, market_value_amount: BigDecimal(amount || "0"), market_value: money,
      realized_gain_amount: BigDecimal("0"), realized_gain: Money.new(0, "BRL"),
      unrealized_gain_amount: BigDecimal("0"), unrealized_gain: Money.new(0, "BRL"),
      net_cash_flow_amount: BigDecimal("0"), net_cash_flow: Money.new(0, "BRL"),
      status:, position_results: [], cash_flows:
    )
  end

  def cash_flow(date:, amount:)
    Performance::Portfolio::CashFlow.new(traded_on: date, amount: BigDecimal(amount))
  end

  def configured_portfolio
    ConfiguredPortfolio.new(
      exchange_rate_service: HistoricalExchangeRate::Service.new(provider: Struct.new(:identifier).new("test_provider")),
      daily_closing_price_provider: "test_provider"
    )
  end

  def create_trade(instrument:, traded_on:)
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on:, quantity: 1, unit_price: "10", fees_cents: 0, currency: "USD"
    )
  end

  def create_daily_close(instrument:, date:, close_price:)
    DailyClosingPrice.create!(
      instrument:, trading_date: date, close_price:, currency: "USD", provider: "test_provider", observed_at: Time.current
    )
  end

  def create_exchange_rate(date:, rate:)
    HistoricalExchangeRate.create!(
      base_currency: "USD", quote_currency: "BRL", rate_date: date, rate:, provider: "test_provider",
      observed_at: Time.current, fetched_at: Time.current
    )
  end
end
