require "test_helper"

class InstrumentPerformanceObservationTest < ActiveSupport::TestCase
  EXACT_AMOUNTS = {
    market_value_amount: "123.123456789012345678901234567890",
    cost_basis_amount: "100.000000000000000000000000000001",
    realized_gain_amount: "7.777777777777777777777777777777",
    unrealized_gain_amount: "15.345679011234567901123456790112",
    net_cash_flow_amount: "92.222222222222222222222222222224"
  }.freeze

  test "stores every analytical amount and cumulative flow exactly" do
    observation = build_observation(
      reporting_currency: " usd ",
      cash_flow_total: Rational(7, 3),
      dated_cash_flow_total: Rational(70_021, 3)
    )

    assert observation.save
    observation.reload
    assert_equal "USD", observation.reporting_currency
    EXACT_AMOUNTS.each do |attribute, value|
      assert_equal BigDecimal(value), observation.public_send(attribute)
    end
    assert_equal Rational(7, 3), observation.cash_flow_total
    assert_equal Rational(70_021, 3), observation.dated_cash_flow_total
  end

  test "requires every monetary amount unless source history is missing" do
    available = build_observation(cost_basis_amount: nil)
    missing = build_observation(status: :missing, **EXACT_AMOUNTS.transform_values { nil })

    assert_not_predicate available, :valid?
    assert_predicate missing, :valid?
  end

  test "prevents duplicate observations for a target and date" do
    build_observation.save!
    duplicate = build_observation

    assert_not_predicate duplicate, :valid?
    assert duplicate.errors.added?(:observed_on, :taken, value: duplicate.observed_on)
  end

  test "reports staleness and scopes rows chronologically" do
    later = build_observation(observed_on: Date.new(2026, 9, 2), stale_at: Time.current)
    earlier = build_observation
    later.save!
    earlier.save!

    assert_not_predicate earlier, :stale?
    assert_predicate later, :stale?
    assert_equal [ earlier, later ], InstrumentPerformanceObservation.for_range(
      from: earlier.observed_on,
      to: later.observed_on
    ).to_a
    assert_equal [ later ], InstrumentPerformanceObservation.stale.to_a
  end

  test "database constraints reject status amount and generation mismatches" do
    observation = build_observation
    observation.save!

    assert_raises(ActiveRecord::StatementInvalid) { observation.update_columns(status: "invalid") }
    assert_raises(ActiveRecord::StatementInvalid) { observation.update_columns(market_value_amount: nil) }
    assert_raises(ActiveRecord::StatementInvalid) { observation.update_columns(status: "missing") }
    assert_raises(ActiveRecord::StatementInvalid) { observation.update_columns(source_generation: -1) }
  end

  test "derived rows cascade with their user and instrument" do
    user = users(:two)
    instrument = Instrument.create!(ticker: "AAPL", exchange: "XNAS", name: "Apple", currency: "USD")
    materialization = InstrumentPerformanceMaterialization.create!(user:, instrument:, reporting_currency: "USD")
    observation = build_observation(user:, instrument:)
    observation.save!

    assert_difference([ "InstrumentPerformanceMaterialization.count", "InstrumentPerformanceObservation.count" ], -1) do
      instrument.destroy!
    end
    assert_not InstrumentPerformanceMaterialization.exists?(materialization.id)
    assert_not InstrumentPerformanceObservation.exists?(observation.id)

    instrument = Instrument.create!(ticker: "MSFT", exchange: "XNAS", name: "Microsoft", currency: "USD")
    InstrumentPerformanceMaterialization.create!(user:, instrument:, reporting_currency: "USD")
    build_observation(user:, instrument:).save!

    assert_difference([ "InstrumentPerformanceMaterialization.count", "InstrumentPerformanceObservation.count" ], -1) do
      user.destroy!
    end
  end

  private

  def build_observation(**attributes)
    InstrumentPerformanceObservation.new({
      user: users(:owner),
      instrument: instruments(:voo_arcx),
      observed_on: Date.new(2026, 9, 1),
      reporting_currency: "USD",
      **EXACT_AMOUNTS,
      status: :available,
      generated_at: Time.current
    }.merge(attributes))
  end
end
