require "test_helper"

class Performance::SeriesTest < ActiveSupport::TestCase
  setup do
    @user = users(:owner)
    @from = Date.new(2026, 8, 26)
    @to = Date.new(2026, 8, 28)
    @store = StubStore.new
    @refresher = StubRefresher.new
  end

  test "calculates daily values and Modified Dietz returns in one linear pass" do
    @store.add(snapshot(@from, market_value: "100", net_cash_flow: "80"))
    dated_flow_total = 80 * @from.jd + 100 * (@from + 1).jd
    @store.add(snapshot(@from + 1, market_value: "220", net_cash_flow: "180", dated_flow_total:))
    @store.add(snapshot(@to, market_value: "230", net_cash_flow: "180", dated_flow_total:))

    series = calculate

    assert_predicate series, :available?
    assert_equal [ @from, @from + 1, @to ], series.observations.map(&:date)
    assert_equal BigDecimal("20"), series.observations[1].gain_loss_amount
    assert_equal BigDecimal("0.2"), series.observations[1].return_ratio
    assert_equal BigDecimal("30"), series.observations.last.gain_loss_amount
    assert_equal BigDecimal("0.2"), series.observations.last.return_ratio
    assert_empty series.missing_dates
  end

  test "matches the authoritative portfolio and period calculations" do
    Trade.where(user: @user).delete_all
    instrument = Instrument.create!(
      ticker: "SMAT", exchange: "BVMF", name: "Series math stock", currency: "BRL"
    )
    create_trade(instrument:, date: @from, quantity: "2", unit_price: "10")
    create_trade(instrument:, date: @from + 1, quantity: "1.5", unit_price: "12.34567890")
    create_close(instrument:, date: @from, price: "11")
    create_close(instrument:, date: @from + 1, price: "13")
    create_close(instrument:, date: @to, price: "14")
    Performance::ObservationBuilder.new(user: @user).call(from: @from, to: @to)

    series = Performance::Series.for(from: @from, to: @to, user: @user)

    first_observation, *later_observations = series.observations
    assert_equal BigDecimal("0"), first_observation.return_ratio

    later_observations.each do |observation|
      period = Performance::Period.for(from: @from, to: observation.date)
      assert_equal period.closing_valuation.market_value_amount, observation.market_value_amount
      assert_equal period.closing_valuation.net_cash_flow_amount, observation.invested_amount
      assert_equal period.gain_loss_amount, observation.gain_loss_amount
      assert_equal period.return_ratio, observation.return_ratio
    end
  end

  test "uses cumulative net cash flow for the invested line" do
    @store.add(snapshot(@from, market_value: "100", net_cash_flow: "40"))

    result = calculate(to: @from)

    assert_equal BigDecimal("40"), result.observations.first.invested_amount
    assert_equal Money.from_amount(40, "BRL"), result.observations.first.invested_value
    assert_equal BigDecimal("0"), result.observations.first.return_ratio
  end

  test "uses remaining cost basis for an instrument value series" do
    instrument = instruments(:voo_arcx)
    @store.add(snapshot(@from, market_value: "100", net_cash_flow: "80", cost_basis: "70"))

    result = Performance::Series.for(
      from: @from,
      to: @to,
      user: @user,
      instrument:,
      store: @store,
      refresher: @refresher
    )

    assert_equal BigDecimal("70"), result.observations.first.invested_amount
    assert_equal Money.from_amount(70, "BRL"), result.observations.first.invested_value
    assert_equal [ instrument ], @refresher.instruments
  end

  test "leaves gain on cost unavailable when cumulative purchases are zero" do
    instrument = instruments(:voo_arcx)
    @store.add(snapshot(@from, invested: "0"))

    result = Performance::Series.for(
      from: @from, to: @from, user: @user, instrument:, store: @store, refresher: @refresher
    )

    assert_nil result.observations.first.gain_on_cost_ratio
  end

  test "matches period math for fractional sales fees closure reopening and multiple currencies" do
    Trade.where(user: @user).delete_all
    from = Date.new(2026, 8, 24)
    to = from + 4.days
    domestic = instruments(:petr4_bvmf)
    foreign = instruments(:voo_arcx)
    [
      [ domestic, 0, :buy, "5.12345678", "10.12345678", 13 ],
      [ domestic, 1, :sell, "1.12345678", "12.87654321", 7 ],
      [ domestic, 1, :buy, "0.5", "11.5", 2 ],
      [ domestic, 2, :sell, "4.5", "14.25", 11 ],
      [ domestic, 3, :buy, "0.00000001", "98765.43218765", 1 ],
      [ foreign, 0, :buy, "0.12345678", "100.12345678", 3 ],
      [ foreign, 4, :sell, "0.02345678", "130.98765432", 2 ]
    ].each do |instrument, offset, side, quantity, unit_price, fees_cents|
      @user.trades.create!(
        instrument:, traded_on: from + offset, side:, quantity:, unit_price:,
        fees_cents:, currency: instrument.currency
      )
    end
    (from..to).each_with_index do |date, offset|
      [ domestic, foreign ].each do |instrument|
        create_close(instrument:, date:, price: (100 + offset).to_s)
      end
      HistoricalExchangeRate.create!(
        base_currency: "USD", quote_currency: "BRL", rate_date: date,
        rate: BigDecimal("5") + BigDecimal("0.01") * offset,
        provider: MarketData::YahooFinance::FX_CONFIGURATION.identifier,
        observed_at: date.to_time, fetched_at: Time.current
      )
    end
    Performance::ObservationBuilder.new(user: @user).call(from:, to:)

    first_observation, *later_observations = Performance::Series.for(from:, to:, user: @user).observations
    assert_equal BigDecimal("0"), first_observation.return_ratio

    later_observations.each do |observation|
      period = Performance::Period.for(from:, to: observation.date)
      assert_equal period.closing_valuation.market_value_amount, observation.market_value_amount
      assert_equal period.closing_valuation.net_cash_flow_amount, observation.invested_amount
      assert_equal period.gain_loss_amount, observation.gain_loss_amount
      assert_equal period.return_ratio, observation.return_ratio
    end
  end

  test "enqueues missing dates and reports a pending range" do
    @refresher.result = :queued

    result = calculate

    assert_predicate result, :pending?
    assert_predicate result, :queued?
    assert_predicate result, :refreshing?
    assert_equal [ [ @from, @to ] ], @refresher.ranges
    assert_equal [ @from, @from + 1, @to ], result.missing_dates
  end

  test "keeps exact cached values while a stale range rebuilds" do
    dates.each { |date| @store.add(snapshot(date, stale_at: Time.current)) }
    @refresher.result = :active

    result = calculate

    assert_predicate result, :stale?
    assert_predicate result, :refreshing?
    assert_predicate result, :displayable?
    assert result.observations.all?(&:stale?)
  end

  test "reports partial data without converting gaps to zero" do
    @store.add(snapshot(@from))
    @refresher.result = :queued

    result = calculate

    assert_predicate result, :partial?
    assert_predicate result, :displayable?
    assert_nil result.observations.last.market_value_amount
  end

  test "an absent or source-missing opening leaves later values visible without returns" do
    @store.add(snapshot(@to))
    result = calculate
    assert_equal BigDecimal("100"), result.observations.last.market_value_amount
    assert_nil result.observations.last.gain_loss_amount
    assert_nil result.observations.last.return_ratio

    @store.add(snapshot(@from, status: :missing, market_value: nil, net_cash_flow: nil))
    assert_nil calculate.observations.last.return_ratio
  end

  test "does not derive a return from mixed old and rebuilt endpoints" do
    old_opening = snapshot(@from, market_value: "100", net_cash_flow: "100", stale_at: Time.current)
    old_closing = snapshot(@to, market_value: "110", net_cash_flow: "100", stale_at: Time.current)
    @store.add(old_opening)
    @store.add(old_closing)
    assert_equal BigDecimal("0.1"), calculate.observations.last.return_ratio

    rebuilt_opening = snapshot(@from, market_value: "200", net_cash_flow: "200").with(source_generation: 1)
    @store.add(rebuilt_opening)
    mixed = calculate.observations.last
    assert_equal BigDecimal("110"), mixed.market_value_amount
    assert_nil mixed.gain_loss_amount
    assert_nil mixed.return_ratio

    rebuilt_closing = snapshot(@to, market_value: "220", net_cash_flow: "200").with(source_generation: 1)
    @store.add(rebuilt_closing)
    assert_equal BigDecimal("0.1"), calculate.observations.last.return_ratio

    @store.add(old_opening)
    assert_nil calculate.observations.last.return_ratio
  end

  test "fresh endpoints from different generations still compare when the opening was unaffected" do
    @store.add(snapshot(@from))
    @store.add(snapshot(@to, market_value: "110").with(source_generation: 1))

    assert_equal BigDecimal("0.1"), calculate.observations.last.return_ratio
  end

  test "a newer generation only makes observations inside the dirty range stale" do
    dates.each { |date| @store.add(snapshot(date)) }
    materialization = PortfolioPerformanceMaterialization.for(user: @user)
    materialization.request!(from: @to, to: Date.current, source_changed: true)

    result = calculate

    assert_predicate result.observations.first, :available?
    assert_predicate result.observations.last, :stale?
    assert_predicate result, :refreshing?
  end

  test "reports a failed rebuild" do
    @refresher.result = :failed

    assert_predicate calculate, :failed?
  end

  test "preserves source-missing history without repeatedly rebuilding it" do
    dates.each { |date| @store.add(snapshot(date)) }
    @store.add(snapshot(@from + 1, status: :missing, market_value: nil, net_cash_flow: nil))

    result = calculate

    assert_predicate result, :partial?
    assert_empty @refresher.ranges
    assert_equal BigDecimal("0"), result.observations.last.return_ratio
  end

  test "returns recover after a missing close even with trades during the gap" do
    Trade.where(user: @user).delete_all
    from = Date.new(2026, 8, 1)
    to = from + 12
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, date: from, quantity: "2", unit_price: "10")
    create_trade(instrument:, date: from + 9, quantity: "1.23456789", unit_price: "12.34567890")
    create_close(instrument:, date: from, price: "11")
    create_close(instrument:, date: to, price: "14")
    Performance::ObservationBuilder.new(user: @user).call(from:, to:)

    series = Performance::Series.for(from:, to:, user: @user)
    period = Performance::Period.for(from:, to:)

    assert_predicate series.observations[-2], :missing?
    assert_predicate period, :available?
    assert_equal period.gain_loss_amount, series.observations.last.gain_loss_amount
    assert_equal period.return_ratio, series.observations.last.return_ratio
  end

  test "viewing all history only requests the dirty tail with the real refresher" do
    dates.each { |date| @store.add(snapshot(date)) }
    materialization = PortfolioPerformanceMaterialization.for(user: @user)
    materialization.request!(from: @to, to: @to, source_changed: true)

    Performance::Series.for(from: @from, to: @to, user: @user, store: @store)

    assert_equal @to..@to, materialization.reload.requested_range
  end

  test "fresh short and long ranges use only two reads without loading trades" do
    from = @to - 365
    store = Performance::ObservationStore.new(user: @user)
    PortfolioPerformanceMaterialization.for(user: @user)
    (from..@to).each do |date|
      PortfolioPerformanceObservation.create!(
        user: @user, reporting_currency: "BRL", observed_on: date,
        market_value_amount: "100", net_cash_flow_amount: "80",
        status: :available, generated_at: Time.current
      )
    end

    [ @to - 7, from ].each do |start_date|
      queries = []
      listener = ->(event) { queries << event.payload[:sql] unless event.payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
        ActiveRecord::Base.uncached do
          Performance::Series.for(from: start_date, to: @to, user: @user, store:)
        end
      end

      assert_equal 2, queries.size, queries.join("\n")
      assert queries.none? { |query| query.include?('FROM "trades"') }
    end
  end

  test "reports unavailable when the entire range lacks source history" do
    dates.each do |date|
      @store.add(snapshot(date, status: :missing, market_value: nil, net_cash_flow: nil))
    end

    assert_predicate calculate, :missing?
    assert_empty @refresher.ranges
  end

  test "reports an empty range when all daily values are zero" do
    dates.each { |date| @store.add(snapshot(date, market_value: "0", net_cash_flow: "0", status: :empty)) }

    assert_predicate calculate, :empty?
  end

  test "does not confuse an available closed position with no history" do
    dates.each { |date| @store.add(snapshot(date, market_value: "0", net_cash_flow: "-10")) }

    result = Performance::Series.for(
      from: @from,
      to: @to,
      user: @user,
      instrument: instruments(:voo_arcx),
      store: @store,
      refresher: @refresher
    )

    assert_predicate result, :available?
  end

  test "rejects invalid or future ranges" do
    assert_raises(ArgumentError) { calculate(from: @to, to: @from) }
    assert_raises(ArgumentError) { calculate(from: @from.to_s) }
    assert_raises(ArgumentError) { calculate(to: Date.current + 1) }
  end

  private

  Snapshot = Data.define(
    :observed_on, :market_value_amount, :cost_basis_amount, :net_cash_flow_amount,
    :realized_gain_amount, :unrealized_gain_amount, :invested_amount,
    :status, :stale_at, :source_generation, :cash_flow_total, :dated_cash_flow_total
  ) do
    def stale? = stale_at.present?
    def missing? = status == :missing
    def empty? = status == :empty
  end

  class StubStore
    def initialize
      @records = {}
    end

    def add(record)
      @records[record.observed_on] = record
    end

    def read(from:, to:)
      @records.slice(*(from..to).to_a)
    end
  end

  class StubRefresher
    attr_accessor :result
    attr_reader :ranges, :instruments

    def initialize
      @result = :queued
      @ranges = []
      @instruments = []
    end

    def enqueue(user:, from:, to:, reporting_currency:, instrument: nil)
      raise "missing inputs" unless user && reporting_currency

      ranges << [ from, to ]
      instruments << instrument if instrument
      result
    end
  end

  def calculate(from: @from, to: @to)
    Performance::Series.for(
      from:, to:, user: @user, store: @store, refresher: @refresher
    )
  end

  def dates
    (@from..@to).to_a
  end

  def snapshot(date, market_value: "100", cost_basis: nil, net_cash_flow: "80", status: :available, stale_at: nil,
    dated_flow_total: nil, realized_gain: "0", unrealized_gain: "20", invested: "80")
    Snapshot.new(
      observed_on: date,
      market_value_amount: market_value && BigDecimal(market_value),
      cost_basis_amount: cost_basis && BigDecimal(cost_basis),
      net_cash_flow_amount: net_cash_flow && BigDecimal(net_cash_flow),
      realized_gain_amount: realized_gain && BigDecimal(realized_gain),
      unrealized_gain_amount: unrealized_gain && BigDecimal(unrealized_gain),
      invested_amount: invested && BigDecimal(invested),
      cash_flow_total: net_cash_flow.to_r,
      dated_cash_flow_total: dated_flow_total || net_cash_flow.to_r * @from.jd,
      status:,
      stale_at:,
      source_generation: 0
    )
  end

  def create_trade(instrument:, date:, quantity:, unit_price:)
    @user.trades.create!(
      instrument:, side: :buy, traded_on: date, quantity:, unit_price:,
      fees_cents: 0, currency: "BRL"
    )
  end

  def create_close(instrument:, date:, price:)
    DailyClosingPrice.create!(
      instrument:, trading_date: date, close_price: price, currency: instrument.currency,
      provider: "yahoo_finance", observed_at: Time.current
    )
  end
end
