require "application_system_test_case"

class PortfolioPlansTest < ApplicationSystemTestCase
  test "configures a target mix and calculates a buy-only recommendation" do
    prepare_holdings

    visit portfolio_plan_path
    assert_text "Shape your portfolio"
    assert_text "Stock"
    assert_text "Allocation bond"

    find("input[name='portfolio_allocation[asset_targets][stock]']").set("60")
    fill_in "portfolio_allocation_asset_targets_bond", with: "40"
    find("input[name='portfolio_allocation[instrument_targets][#{@stock.id}]']").set("100")
    find("input[name='portfolio_allocation[instrument_targets][#{@bond.id}]']").set("100")
    click_on "Save targets"

    assert_text "Allocation targets saved."
    fill_in "New money (BRL)", with: "100"
    click_on "Calculate"

    assert_current_path portfolio_plan_path(contribution: "100", instrument_count: "", mode: "buy_only")
    assert_selector "turbo-frame#portfolio-plan-calculation"
    assert_text "What would move you closer?"
    assert_text "These are estimates, not orders."
    assert_text "Buy"
    assert_no_text "0.00000000"
    assert_page_accessible(label: "portfolio plan")
  end

  test "surfaces allocation planning from goals and balances the percentage bars" do
    prepare_holdings

    visit investment_goals_path
    assert_text "Shape your portfolio mix"
    assert_text "Set target percentages for each asset type"
    click_on "Open allocation planner"
    assert_selector "form[data-controller='portfolio-allocation-form']"
    assert_selector "#portfolio_allocation_asset_targets_range_stock[data-action*='input->portfolio-allocation-form#move']"

    find("input[name='portfolio_allocation[asset_targets][stock]']").set("60")
    fill_in "portfolio_allocation_asset_targets_bond", with: "40"
    find("#portfolio_allocation_asset_targets_range_stock").set("70")

    assert_text "70%"
    assert_field "portfolio_allocation_asset_targets_bond", with: "40"
    assert_selector "#portfolio_allocation_instrument_targets_range_#{@stock.id}.h-5"
    assert_field "portfolio_allocation_instrument_targets_#{@stock.id}", with: ""

    find("#portfolio_allocation_instrument_targets_range_#{@stock.id}").set("35")
    assert_field "portfolio_allocation_instrument_targets_#{@stock.id}", with: "35"
  end

  test "shows a screen-only shopping list for the selected instrument count" do
    prepare_holdings

    visit portfolio_plan_path
    find("input[name='portfolio_allocation[asset_targets][stock]']").set("60")
    fill_in "portfolio_allocation_asset_targets_bond", with: "40"
    click_on "Save targets"
    assert_text "Allocation targets saved."

    fill_in "Instruments to buy", with: "1"
    fill_in "New money (BRL)", with: "100"
    click_on "Calculate"

    assert_selector "input[data-shopping-list-item]", count: 1
    assert_text "Over target by"
    find("input[data-shopping-list-item]").check
    assert_selector "input[data-shopping-list-item]:checked", count: 1
  end

  test "uses stacked comparison cards below the wide layout breakpoint" do
    prepare_holdings

    visit portfolio_plan_path
    find("input[name='portfolio_allocation[asset_targets][stock]']").set("60")
    fill_in "portfolio_allocation_asset_targets_bond", with: "40"
    click_on "Save targets"
    fill_in "New money (BRL)", with: "100"
    click_on "Calculate"
    page.current_window.resize_to(800, 844)

    assert_selector "[data-portfolio-plan-comparisons='mobile']", visible: true
    assert_no_selector "[data-portfolio-plan-comparisons='desktop']", visible: true
    assert_selector "[data-portfolio-plan-comparisons='mobile'] article", count: 2
    assert_text "CURRENT"
    assert_text "SUGGESTED MOVE"
  end

  test "explains that a plan needs fresh data before recommending" do
    prepare_holdings

    visit portfolio_plan_path
    find("input[name='portfolio_allocation[asset_targets][stock]']").set("100")
    find("input[name='portfolio_allocation[instrument_targets][#{@stock.id}]']").set("100")
    click_on "Save targets"
    assert_text "Allocation targets saved."

    CurrentMarketPriceCache.new.write(
      instrument: @stock,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "30", currency: "BRL", provider: "yahoo_finance",
        quoted_at: Time.current - 2.hours, fetched_at: Time.current - 2.hours
      )
    )
    visit portfolio_plan_path(contribution: "100", mode: "buy_only")

    assert_text "The plan needs fresh market data"
    assert_text "Open Data health"
  end

  test "fills the remaining asset target and splits blank instruments evenly" do
    prepare_holdings

    visit portfolio_plan_path
    find("input[name='portfolio_allocation[asset_targets][stock]']").set("60")

    assert_field "portfolio_allocation[asset_targets][bond]", with: "40.00"
    assert_field "portfolio_allocation[instrument_targets][#{@stock.id}]", with: ""
    assert_field "portfolio_allocation[instrument_targets][#{@bond.id}]", with: ""

    click_on "Save targets"
    assert_text "Allocation targets saved."
    fill_in "New money (BRL)", with: "100"
    click_on "Calculate"

    assert_text "Buy"
  end

  private

  def prepare_holdings
    Trade.where(user: User.owner).delete_all
    @stock = instruments(:petr4_bvmf)
    @stock.update!(asset_type: :stock)
    @bond = Instrument.create!(ticker: "ALBD", exchange: "BVMF", name: "Allocation bond", currency: "BRL", asset_type: :bond)
    [ [ @stock, 30 ], [ @bond, 20 ] ].each do |instrument, price|
      User.owner.trades.create!(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 1,
        unit_price: price, fees_cents: 0, currency: instrument.currency)
      CurrentMarketPriceCache.new.write(
        instrument:,
        current_market_price: CurrentMarketPrice.new(
          unit_price: price, currency: instrument.currency, provider: "yahoo_finance",
          quoted_at: Time.current - 1.minute, fetched_at: Time.current
        )
      )
    end
  end
end
