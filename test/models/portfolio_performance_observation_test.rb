require "test_helper"

class PortfolioPerformanceObservationTest < ActiveSupport::TestCase
  test "stores exact daily values and normalizes the reporting currency" do
    observation = build_observation(reporting_currency: " brl ")

    assert observation.save
    assert_equal "BRL", observation.reporting_currency
    assert_equal BigDecimal("123.12345678901234567890123456789"), observation.reload.market_value_amount
  end

  test "requires amounts unless source history is missing" do
    available = build_observation(market_value_amount: nil, net_cash_flow_amount: nil)
    missing = build_observation(status: :missing, market_value_amount: nil, net_cash_flow_amount: nil)

    assert_not available.valid?
    assert missing.valid?
  end

  test "prevents duplicate observations for a user currency and date" do
    build_observation.save!
    duplicate = build_observation

    assert_not duplicate.valid?
    assert duplicate.errors.added?(:observed_on, :taken, value: duplicate.observed_on)
  end

  test "reports whether an observation is stale" do
    assert_not_predicate build_observation, :stale?
    assert_predicate build_observation(stale_at: Time.current), :stale?
  end

  test "database constraints reject amounts inconsistent with the source status" do
    observation = build_observation
    observation.save!

    assert_raises(ActiveRecord::StatementInvalid) { observation.update_columns(market_value_amount: nil) }
    assert_raises(ActiveRecord::StatementInvalid) { observation.update_columns(status: "missing") }
    assert_raises(ActiveRecord::StatementInvalid) { observation.update_columns(source_generation: -1) }
  end

  private

  def build_observation(**attributes)
    PortfolioPerformanceObservation.new({
      user: users(:owner),
      observed_on: Date.new(2026, 9, 1),
      reporting_currency: "BRL",
      market_value_amount: "123.123456789012345678901234567890",
      net_cash_flow_amount: "100.000000000000000000000000000001",
      status: :available,
      generated_at: Time.current
    }.merge(attributes))
  end
end
