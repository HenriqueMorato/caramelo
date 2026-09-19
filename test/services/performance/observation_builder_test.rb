require "test_helper"

class Performance::ObservationBuilderTest < ActiveSupport::TestCase
  setup do
    @user = users(:owner)
    @from = Date.new(2026, 8, 30)
    @to = Date.new(2026, 9, 1)
    @store = Performance::ObservationStore.new(user: @user)
    @portfolio = RecordingPortfolio.new(user: @user)
    @builder = Performance::ObservationBuilder.new(
      user: @user,
      store: @store,
      portfolio: @portfolio
    )
  end

  test "builds every missing calendar date with one preloaded trade collection" do
    result = @builder.call(from: @from, to: @to)

    assert_equal 3, result.built_count
    assert_equal 0, result.skipped_count
    assert_equal [ @from, @from + 1, @to ], @store.read(from: @from, to: @to).keys
    assert_equal 1, @portfolio.trade_collection_ids.uniq.length
    assert_equal 1, @portfolio.corporate_action_collection_ids.uniq.length
  end

  test "skips fresh observations and replaces stale ones" do
    @store.write(@portfolio.valuation(@from), generated_at: Time.current)
    @store.write(@portfolio.valuation(@from + 1), generated_at: Time.current)
    @store.stale_from(@from + 1)

    result = @builder.call(from: @from, to: @to)

    assert_equal 2, result.built_count
    assert_equal 1, result.skipped_count
    assert_equal [ @from + 1, @to ], @portfolio.dates
    assert_empty @store.read(from: @from, to: @to).values.select(&:stale?)
  end

  test "returns without loading trades when every observation is fresh" do
    (@from..@to).each do |date|
      @store.write(@portfolio.valuation(date), generated_at: Time.current)
    end

    result = @builder.call(from: @from, to: @to)

    assert_equal 0, result.built_count
    assert_equal 3, result.skipped_count
    assert_empty @portfolio.dates
  end

  test "reusing a builder reloads trades and the requested range" do
    first = @builder.call(from: @from, to: @from)
    trades(:owner_voo_buy).update!(quantity: "9")

    second = @builder.call(from: @to, to: @to)

    assert_equal [ @from, @to ], @portfolio.dates
    assert_equal 2, @portfolio.trade_collection_ids.uniq.length
    assert_equal 2, @portfolio.corporate_action_collection_ids.uniq.length
    assert_operator second.source_generation, :>, first.source_generation
    assert_equal @to, second.from
    assert_equal 1, second.built_count
  end

  test "rejects invalid ranges" do
    assert_raises(ArgumentError) { @builder.call(from: @to, to: @from) }
    assert_raises(ArgumentError) { @builder.call(from: @from.to_s, to: @to) }
    assert_raises(ArgumentError) { @builder.call(from: @from, to: Date.current + 1) }
  end

  test "never publishes a trade snapshot superseded during calculation" do
    trade = trades(:owner_voo_buy)
    @portfolio.during_valuation = -> { Trade.find(trade.id).update!(quantity: "9") }

    result = @builder.call(from: @from, to: @to)

    assert_equal 0, result.built_count
    assert_empty @store.read(from: @from, to: @to)
    assert_predicate PortfolioPerformanceMaterialization.for(user: @user), :pending?
  end

  test "cannot recreate observations after the last trade is deleted during a build" do
    @portfolio.during_valuation = -> { trades(:owner_voo_buy).destroy! }

    result = @builder.call(from: @from, to: @to)

    assert_equal 0, result.built_count
    assert_empty @store.read(from: @from, to: @to)
  end

  test "clears derived observations when a resumed build has no trades" do
    @store.write(@portfolio.valuation(@from))
    Trade.where(user: @user).delete_all

    result = @builder.call(from: @from, to: @to)

    assert_equal 0, result.built_count
    assert_empty @store.read(from: @from, to: @to)
  end

  test "scopes an instrument build before replay and publishes its position result" do
    instrument = instruments(:voo_arcx)
    store = InstrumentPerformance::ObservationStore.new(
      user: @user, instrument:, reporting_currency: instrument.currency
    )
    portfolio = RecordingInstrumentPortfolio.new(user: @user, instrument:)
    builder = Performance::ObservationBuilder.new(
      user: @user,
      instrument:,
      reporting_currency: instrument.currency,
      store:,
      portfolio:
    )

    result = builder.call(from: @from, to: @to)

    assert_equal 3, result.built_count
    assert portfolio.trade_sets.all? { |set| set.all? { |trade| trade.instrument == instrument } }
    assert_equal 1, portfolio.trade_collection_ids.uniq.length
    record = store.read(from: @from, to: @to).fetch(@to)
    assert_equal BigDecimal("90"), record.cost_basis_amount
    assert_equal BigDecimal("10"), record.unrealized_gain_amount
    assert_equal BigDecimal("90"), record.invested_amount
  end

  test "empty-portfolio cleanup cannot erase observations after a new trade commits" do
    @store.write(@portfolio.valuation(@from))
    Trade.where(user: @user).delete_all
    collection = @user.trades.includes(:instrument).strict_loading.order(:traded_on, :id)
    user = @user
    instrument = instruments(:petr4_bvmf)
    traded_on = @from
    snapshot = -> do
      Trade.create!(user:,
        instrument:, side: :buy, traded_on:,
        quantity: 1, unit_price: 10, fees_cents: 0, currency: "BRL"
      )
      []
    end

    collection.define_singleton_method(:includes) { |*| self }
    collection.define_singleton_method(:strict_loading) { self }
    collection.define_singleton_method(:order) { |*| self }
    collection.define_singleton_method(:to_a, snapshot)
    @user.define_singleton_method(:trades) { collection }
    @builder.call(from: @from, to: @to)

    assert_equal 1, @store.read(from: @from, to: @to).size
    assert_predicate PortfolioPerformanceMaterialization.for(user: @user), :pending?
  end

  class RecordingPortfolio
    attr_accessor :during_valuation
    attr_reader :dates, :trade_collection_ids, :corporate_action_collection_ids

    Valuation = Data.define(:valuation_date, :market_value_amount, :net_cash_flow_amount, :status, :cash_flows)

    def initialize(user:)
      @user = user
      @dates = []
      @trade_collection_ids = []
      @corporate_action_collection_ids = []
    end

    def for(valuation_date:, owner:, trades:, corporate_actions:, reporting_currency:)
      raise "wrong owner" unless owner == @user
      raise "wrong reporting currency" unless reporting_currency == "BRL"

      dates << valuation_date
      trade_collection_ids << trades.object_id
      corporate_action_collection_ids << corporate_actions.object_id
      during_valuation&.call
      valuation(valuation_date)
    end

    def valuation(date)
      Valuation.new(
        valuation_date: date,
        market_value_amount: BigDecimal("100"),
        net_cash_flow_amount: BigDecimal("80"),
        cash_flows: [],
        status: :available
      )
    end
  end

  class RecordingInstrumentPortfolio
    attr_reader :dates, :trade_sets, :trade_collection_ids

    PositionResult = Data.define(
      :instrument, :reporting_cost_basis_amount, :market_value_amount,
      :realized_gain_amount, :unrealized_gain_amount, :net_cash_flow_amount,
      :investment_income_amount, :invested_amount
    )
    Valuation = Data.define(:valuation_date, :status, :position_results, :cash_flows)

    def initialize(user:, instrument:)
      @user = user
      @instrument = instrument
      @dates = []
      @trade_sets = []
      @trade_collection_ids = []
    end

    def for(valuation_date:, owner:, instrument:, trades:, corporate_actions:, reporting_currency:)
      raise "wrong owner" unless owner == @user
      raise "wrong instrument" unless instrument == @instrument
      raise "wrong reporting currency" unless reporting_currency == @instrument.currency

      trade_sets << trades
      raise "wrong corporate actions" unless corporate_actions.all? { |action| action.instrument == instrument }
      trade_collection_ids << trades.object_id
      dates << valuation_date
      position = PositionResult.new(
        instrument:,
        reporting_cost_basis_amount: BigDecimal("90"),
        market_value_amount: BigDecimal("100"),
        realized_gain_amount: BigDecimal("0"),
        unrealized_gain_amount: BigDecimal("10"),
        net_cash_flow_amount: BigDecimal("90"),
        investment_income_amount: BigDecimal("0"),
        invested_amount: BigDecimal("90")
      )
      Valuation.new(valuation_date:, status: :available, position_results: [ position ], cash_flows: [])
    end
  end
end
