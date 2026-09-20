require "test_helper"

class CorporateActions::CashDistributionValueTest < ActiveSupport::TestCase
  setup do
    @date = Date.new(2026, 8, 28)
    @provider = Struct.new(:identifier).new("income_test")
    @exchange_rates = HistoricalExchangeRate::Service.new(provider: @provider)
    @action = CorporateAction.new(
      user: users(:owner), instrument: instruments(:voo_arcx), kind: :dividend,
      paid_on: @date,
      gross_amount_cents: 250, withholding_tax_cents: 50, net_amount_cents: 200,
      currency: "USD", source: "manual"
    )
  end

  test "returns the exact net distribution in the reporting currency" do
    @action.ex_date = @date - 3.days
    create_rate(rate: "5.12345678", rate_date: @action.ex_date)

    result = CorporateActions::CashDistributionValue.for(
      corporate_action: @action, reporting_currency: "BRL", exchange_rates: @exchange_rates
    )

    assert_predicate result, :available?
    assert_not_predicate result, :missing?
    assert_equal BigDecimal("10.24691356"), result.amount
    assert_equal "BRL", result.currency
    assert_equal @action.ex_date, result.exchange_rate_lookup.exchange_rate.rate_date
  end

  test "uses a synthetic one-to-one rate for native income" do
    result = CorporateActions::CashDistributionValue.for(
      corporate_action: @action, reporting_currency: "USD", exchange_rates: @exchange_rates
    )

    assert_predicate result, :available?
    assert_equal BigDecimal("2"), result.amount
    assert_predicate result.exchange_rate_lookup, :same_currency?
  end

  test "reports missing historical FX without substituting a current rate" do
    result = CorporateActions::CashDistributionValue.for(
      corporate_action: @action, reporting_currency: "BRL", exchange_rates: @exchange_rates
    )

    assert_predicate result, :missing?
    assert_nil result.amount
  end

  private

  def create_rate(rate:, rate_date: @date)
    HistoricalExchangeRate.create!(
      base_currency: "USD", quote_currency: "BRL", rate_date:, rate:,
      provider: @provider.identifier, observed_at: Time.current, fetched_at: Time.current
    )
  end
end
