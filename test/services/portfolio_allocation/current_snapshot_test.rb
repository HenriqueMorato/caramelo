require "test_helper"

class PortfolioAllocation::CurrentSnapshotTest < ActiveSupport::TestCase
  setup do
    @owner = users(:owner)
    Trade.where(user: @owner).delete_all
    PositionMaterialization.where(user: @owner).delete_all
    @instrument = Instrument.create!(
      ticker: "SNAP", exchange: "BVMF", name: "Snapshot holding", currency: "BRL", asset_type: :stock
    )
  end

  test "returns an empty snapshot when the account has no positions" do
    result = build_snapshot

    assert_predicate result, :empty?
    assert_empty result.holdings
    assert_equal BigDecimal("0"), result.total_amount
  end

  test "returns available holdings with exact value and unit price" do
    buy(@instrument, quantity: 2)

    result = build_snapshot(lookup: quote_lookup(unit_price: "12"))

    assert_predicate result, :available?
    assert_equal BigDecimal("24"), result.total_amount
    assert_equal BigDecimal("12"), result.holdings.first.price_amount
    assert_empty result.issues
  end

  test "reports missing prices and exchange rates as incomplete" do
    buy(@instrument)
    missing_price = build_snapshot(lookup: missing_price_lookup)

    assert_predicate missing_price, :incomplete?
    assert_equal :missing, missing_price.issues.first.kind
    assert_nil missing_price.total_amount

    reset_positions!
    foreign = Instrument.create!(
      ticker: "SNFX", exchange: "XNAS", name: "Foreign snapshot", currency: "USD", asset_type: :stock
    )
    buy(foreign)
    missing_fx = build_snapshot(
      instrument: foreign, lookup: quote_lookup(currency: "USD"), exchange_lookup: missing_exchange_lookup
    )

    assert_predicate missing_fx, :incomplete?
    assert_equal :missing, missing_fx.issues.first.kind
  end

  test "reports stale prices and stale exchange rates as incomplete" do
    buy(@instrument)
    stale_price = build_snapshot(lookup: quote_lookup(fetched_at: 1.hour.ago))

    assert_predicate stale_price, :incomplete?
    assert_equal :stale, stale_price.issues.first.kind

    reset_positions!
    foreign = Instrument.create!(
      ticker: "STFX", exchange: "XNAS", name: "Stale FX snapshot", currency: "USD", asset_type: :stock
    )
    buy(foreign)
    stale_fx = build_snapshot(
      instrument: foreign, lookup: quote_lookup(currency: "USD"), exchange_lookup: exchange_lookup(stale: true)
    )

    assert_predicate stale_fx, :incomplete?
    assert_equal :stale, stale_fx.issues.first.kind
  end

  test "keeps invalid positions visible and ignores closed positions" do
    invalid = Instrument.create!(
      ticker: "SNIV", exchange: "BVMF", name: "Invalid snapshot", currency: "BRL", asset_type: :stock
    )
    @owner.trades.create!(instrument: invalid, side: :sell, traded_on: Date.current, quantity: 1,
      unit_price: 10, fees_cents: 0, currency: invalid.currency)
    closed = Instrument.create!(
      ticker: "SNCL", exchange: "BVMF", name: "Closed snapshot", currency: "BRL", asset_type: :stock
    )
    buy(closed)
    @owner.trades.create!(instrument: closed, side: :sell, traded_on: Date.current, quantity: 1,
      unit_price: 10, fees_cents: 0, currency: closed.currency)

    result = build_snapshot

    assert_predicate result, :incomplete?
    assert_equal [ invalid ], result.holdings.map(&:instrument)
    assert_equal :invalid, result.issues.first.kind
  end

  test "treats a holding without valuation as stale when its quote is stale" do
    snapshot = PortfolioAllocation::CurrentSnapshot.new(
      owner: @owner, reporting_currency: "BRL", market_price_service: Object.new,
      exchange_rate_service: Object.new
    )
    market_price = Data.define(:stale?).new(true)
    holding = PortfolioAllocation::CurrentSnapshot::Holding.new(@instrument, Object.new, market_price, nil, nil, nil, nil)

    issue = snapshot.send(:issue_for, holding)

    assert_equal :stale, issue.kind
  end

  private

  def build_snapshot(instrument: @instrument, lookup: quote_lookup, exchange_lookup: nil)
    test = self
    market_service = Object.new
    market_service.define_singleton_method(:read) { |instrument:| test.send(:lookup_for, instrument, lookup) }
    exchange_service = Object.new
    exchange_service.define_singleton_method(:read) { |base_currency:, quote_currency:| exchange_lookup }

    PortfolioAllocation::CurrentSnapshot.for(
      owner: @owner, reporting_currency: "BRL", market_price_service: market_service,
      exchange_rate_service: exchange_service
    )
  end

  def lookup_for(instrument, lookup)
    return lookup if instrument.currency == lookup_currency(lookup)

    CurrentMarketPriceCache::Lookup.new(current_market_price: nil, status: :missing)
  end

  def lookup_currency(lookup)
    lookup.current_market_price&.currency
  end

  def quote_lookup(unit_price: "10", currency: "BRL", fetched_at: Time.current)
    quote = CurrentMarketPrice.new(
      unit_price:, currency:, provider: "snapshot", quoted_at: Time.current, fetched_at:
    )
    status = quote.stale?(fresh_for: 30.minutes) ? :stale : :fresh
    CurrentMarketPriceCache::Lookup.new(current_market_price: quote, status:)
  end

  def missing_price_lookup
    CurrentMarketPriceCache::Lookup.new(current_market_price: nil, status: :missing)
  end

  def exchange_lookup(stale: false)
    ExchangeRateCache::Lookup.new(
      exchange_rate: ExchangeRate::Rate.new(
        base_currency: "USD", quote_currency: "BRL", rate: BigDecimal("5"),
        observed_at: Time.current, fetched_at: stale ? 1.hour.ago : Time.current, provider: "snapshot"
      ), status: stale ? :stale : :fresh
    )
  end

  def missing_exchange_lookup
    ExchangeRateCache::Lookup.new(exchange_rate: nil, status: :missing)
  end

  def buy(instrument, quantity: 1)
    @owner.trades.create!(instrument:, side: :buy, traded_on: Date.current, quantity:, unit_price: 10,
      fees_cents: 0, currency: instrument.currency)
  end

  def reset_positions!
    Trade.where(user: @owner).delete_all
    PositionMaterialization.where(user: @owner).delete_all
  end
end
