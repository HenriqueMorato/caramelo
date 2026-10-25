require "test_helper"

class PortfolioPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    PortfolioAllocationInstrumentTarget.delete_all
    PortfolioAllocationAssetTarget.delete_all
    PortfolioAllocationPlan.delete_all
    Trade.where(user: User.owner).delete_all
    @stock = instruments(:petr4_bvmf)
    @stock.update!(asset_type: :stock)
    @bond = Instrument.create!(ticker: "ALBD", exchange: "BVMF", name: "Allocation bond", currency: "BRL", asset_type: :bond)
    [ [ @stock, 30 ], [ @bond, 20 ] ].each do |instrument, price|
      User.owner.trades.create!(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 1,
        unit_price: price, fees_cents: 0, currency: instrument.currency)
      write_current_market_price(instrument:, unit_price: price)
    end
  end

  test "creates the current account plan and renders held instruments" do
    get portfolio_plan_url

    assert_response :success
    assert_select "h1", "Shape your portfolio"
    assert_select "input[name='portfolio_allocation[asset_targets][stock]']"
    assert_select "input[name='portfolio_allocation[instrument_targets][#{@stock.id}]']"
    assert_select "p", text: "Set your target mix first"
    assert_equal User.owner, PortfolioAllocationPlan.first.user
  end

  test "saves nested targets without accepting another account" do
    patch portfolio_plan_url, params: {
      portfolio_allocation: {
        asset_targets: { stock: "60", bond: "40" },
        instrument_targets: { @stock.id.to_s => "100", @bond.id.to_s => "100" },
        user_id: users(:one).id
      }
    }

    assert_redirected_to portfolio_plan_url(mode: nil, contribution: nil)
    plan = User.owner.reload.portfolio_allocation_plan
    assert_equal({ "stock" => BigDecimal("60"), "bond" => BigDecimal("40") },
      plan.asset_targets.to_h { |target| [ target.asset_type_key, target.target_percentage ] })
    assert_equal User.owner, plan.user
  end

  test "renders target validation errors without replacing the saved plan" do
    plan = PortfolioAllocationPlan.for(user: User.owner)
    plan.asset_targets.create!(asset_type_key: "stock", target_percentage: 100)
    plan.instrument_targets.create!(instrument: @stock, asset_type_key: "stock", target_percentage: 100)

    patch portfolio_plan_url, params: {
      portfolio_allocation: {
        asset_targets: { stock: "70", bond: "20" },
        instrument_targets: { @stock.id.to_s => "100", @bond.id.to_s => "80" }
      }
    }

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Asset type targets must total 100%/
    assert_select "input[name='portfolio_allocation[asset_targets][stock]'][value='70']"
    assert_select "input[name='portfolio_allocation[asset_targets][bond]'][value='20']"
    assert_select "input[name='portfolio_allocation[instrument_targets][#{@bond.id}]'][value='80']"
    assert_equal [ "stock" ], plan.asset_targets.reload.pluck(:asset_type_key)
  end

  test "calculates a buy-only recommendation from URL-backed inputs" do
    save_targets

    get portfolio_plan_url(contribution: "100", mode: "buy_only")

    assert_response :success
    assert_select "h2", "What would move you closer?"
    assert_select "dd", text: /R\$99,00/
    assert_select "td", text: /Buy/
    assert_select "p", /These are estimates, not orders/
  end

  test "shows the sell quantity for an overweight holding in full rebalance mode" do
    patch portfolio_plan_url, params: {
      portfolio_allocation: {
        asset_targets: { stock: "100", bond: "" },
        instrument_targets: { @stock.id.to_s => "100", @bond.id.to_s => "" }
      }
    }

    get portfolio_plan_url(contribution: "100", mode: "full_rebalance")

    assert_response :success
    assert_select "tbody tr", text: /Sell 1/
  end

  test "renders a calculation error without attempting a recommendation" do
    get portfolio_plan_url(contribution: "not-a-number", mode: "buy_only")

    assert_response :success
    assert_select "[role=alert]", /contribution is invalid/
    assert_select "h2", "What would move you closer?"
  end

  test "does not show a closed holding in the target mix" do
    closed = Instrument.create!(ticker: "CLOSED", exchange: "BVMF", name: "Closed allocation", currency: "BRL", asset_type: :stock)
    User.owner.trades.create!(instrument: closed, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 1,
      unit_price: 10, fees_cents: 0, currency: closed.currency)
    User.owner.trades.create!(instrument: closed, side: :sell, traded_on: Date.new(2026, 1, 2), quantity: 1,
      unit_price: 10, fees_cents: 0, currency: closed.currency)
    invalid = Instrument.create!(ticker: "INVALID", exchange: "BVMF", name: "Invalid allocation", currency: "BRL", asset_type: :stock)
    User.owner.trades.create!(instrument: invalid, side: :sell, traded_on: Date.new(2026, 1, 1), quantity: 1,
      unit_price: 10, fees_cents: 0, currency: invalid.currency)

    get portfolio_plan_url

    assert_response :success
    assert_select "input[name='portfolio_allocation[instrument_targets][#{closed.id}]']", count: 0
  end

  test "redirects when money visibility is hidden" do
    patch money_visibility_url, params: { hidden: "true" }
    get portfolio_plan_url

    assert_redirected_to root_url
  end

  private

  def save_targets
    patch portfolio_plan_url, params: {
      portfolio_allocation: {
        asset_targets: { stock: "60", bond: "40" },
        instrument_targets: { @stock.id.to_s => "100", @bond.id.to_s => "100" }
      }
    }
    assert_response :redirect
  end

  def write_current_market_price(instrument:, unit_price:)
    CurrentMarketPriceCache.new.write(
      instrument:,
      current_market_price: CurrentMarketPrice.new(
        unit_price:, currency: instrument.currency, provider: "yahoo_finance",
        quoted_at: Time.current - 1.minute, fetched_at: Time.current
      )
    )
  end
end
