require "application_system_test_case"

class PortfolioPlansTest < ApplicationSystemTestCase
  test "configures a target mix and calculates a buy-only recommendation" do
    prepare_holdings

    visit portfolio_plan_path
    assert_text "Give your portfolio direction."
    assert_text "Stock"
    assert_text "Crypto"
    assert_text "No instruments yet"
    assert_text "Add money"
    assert_text "Buy & sell"
    assert_selector "form#portfolio-allocation-form"
    assert_selector ".portfolio-plan-mix-bar"
    find(".portfolio-plan-mix-segment[data-asset-key='stock']").hover
    assert_selector ".portfolio-plan-mix-tooltip[data-visible='true']", text: /Stock · 0%/
    assert_text "Inside each allocation"
    assert_selector "#portfolio_plan_mode_buy_only[type='radio'][checked]", visible: :all
    assert_selector ".portfolio-plan-mode-options"
    assert_no_selector "details.portfolio-plan-detail[open]"
    open_allocation_details("Bond")
    open_allocation_details("Stock")
    assert_text "Allocation bond"

    find("input[name='portfolio_allocation[asset_targets][stock]']").set("60")
    assert_selector ".portfolio-plan-mix-segment[data-asset-key='stock'][data-tooltip='Stock · 60%']"
    assert_selector ".portfolio-plan-mix-segment[data-asset-key='bond'][data-tooltip='Bond · 8%']"
    fill_in "portfolio_allocation_asset_targets_bond", with: "40"
    find("input[name='portfolio_allocation[instrument_targets][#{@stock.id}]']").set("100")
    find("input[name='portfolio_allocation[instrument_targets][#{@bond.id}]']").set("100")
    click_on "Save targets"

    assert_text "Allocation targets saved."
    find("input[name='portfolio_allocation[asset_targets][stock]']").set("70")
    assert_selector ".portfolio-plan-mix-segment[data-asset-key='stock'][data-tooltip='Stock · 63.64%']"
    assert_selector ".portfolio-plan-mix-segment[data-asset-key='bond'][data-tooltip='Bond · 36.36%']"
    fill_in "New money (BRL)", with: "0"
    find("button[data-amount='100']").click
    assert_field "New money (BRL)", with: "100"
    find("button[data-amount='1000']").click
    assert_field "New money (BRL)", with: "1100"
    fill_in "New money (BRL)", with: "100"
    click_on "Calculate"

    assert_current_path portfolio_plan_path, ignore_query: true
    assert_selector "turbo-frame#portfolio-plan-calculation"
    assert_text "Put the plan in motion."
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
    open_allocation_details("Stock")
    assert_selector "section[data-controller='portfolio-allocation-form']"
    assert_selector "#portfolio_allocation_asset_targets_range_stock[data-action*='input->portfolio-allocation-form#move']"

    find("input[name='portfolio_allocation[asset_targets][stock]']").set("60")
    fill_in "portfolio_allocation_asset_targets_bond", with: "40"
    find("#portfolio_allocation_asset_targets_range_stock").set("70")

    assert_field "portfolio_allocation_asset_targets_stock", with: "70"
    assert_field "portfolio_allocation_asset_targets_bond", with: "40"
    assert_selector "#portfolio_allocation_instrument_targets_range_#{@stock.id}.h-5"
    assert_field "portfolio_allocation_instrument_targets_#{@stock.id}", with: ""

    find("#portfolio_allocation_instrument_targets_range_#{@stock.id}").set("35")
    assert_field "portfolio_allocation_instrument_targets_#{@stock.id}", with: "35"
  end

  test "updates the asset gap as the target changes" do
    prepare_holdings

    visit portfolio_plan_path
    find("input[name='portfolio_allocation[asset_targets][stock]']").set("60")
    assert_equal "0.00%", find("article.portfolio-plan-allocation-row", text: "Stock").find(".portfolio-plan-gap").text

    find("input[name='portfolio_allocation[asset_targets][stock]']").set("70")
    assert_equal "10.00%", find("article.portfolio-plan-allocation-row", text: "Stock").find(".portfolio-plan-gap").text
    assert_equal "-34.00%", find("article.portfolio-plan-allocation-row", text: "Bond").find(".portfolio-plan-gap").text
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
    open_allocation_details("Stock")
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
    click_link "Open Data health"
    assert_current_path market_data_health_path
  end

  test "fills the remaining asset target and splits blank instruments evenly" do
    prepare_holdings

    visit portfolio_plan_path
    find("input[name='portfolio_allocation[asset_targets][stock]']").set("60")
    open_allocation_details("Stock")
    open_allocation_details("Bond")

    assert_field "portfolio_allocation[asset_targets][bond]", with: "8.00"
    assert_field "portfolio_allocation[instrument_targets][#{@stock.id}]", with: ""
    assert_field "portfolio_allocation[instrument_targets][#{@bond.id}]", with: ""

    click_on "Save targets"
    assert_text "Allocation targets saved."
    fill_in "New money (BRL)", with: "100"
    click_on "Calculate"

    assert_text "Buy"
  end

  test "groups related instruments and marks one as hold" do
    prepare_holdings
    @second_stock = Instrument.create!(ticker: "ALB2", exchange: "BVMF", name: "Second allocation stock", currency: "BRL", asset_type: :stock)
    User.owner.trades.create!(instrument: @second_stock, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 1,
      unit_price: 15, fees_cents: 0, currency: @second_stock.currency)
    CurrentMarketPriceCache.new.write(
      instrument: @second_stock,
      current_market_price: CurrentMarketPrice.new(
        unit_price: 15, currency: @second_stock.currency, provider: "yahoo_finance",
        quoted_at: Time.current - 1.minute, fetched_at: Time.current
      )
    )

    visit portfolio_plan_path
    open_allocation_details("Stock")
    fill_in "portfolio_allocation_asset_targets_stock", with: "60"
    fill_in "portfolio_allocation_asset_targets_bond", with: "40"
    click_on "Add instrument group"
    assert_selector "details[data-controller='allocation-group'][open]", count: 1
    within "details[data-controller='allocation-group']" do
      fill_in "Group name", with: "ETF alternatives"
      fill_in "Group share %", with: "100"
      find("input[id$='_members_#{@stock.id}_selected']").check
      find("input[id$='_members_#{@second_stock.id}_selected']").check
      find("select[id$='_members_#{@stock.id}_purchase_policy']").select "Hold"
      find("select[id$='_members_#{@second_stock.id}_purchase_policy']").select "Buy"
    end
    click_on "Save targets"

    assert_text "Allocation targets saved."
    fill_in "New money (BRL)", with: "100"
    click_on "Calculate"

    assert_text "ETF alternatives · Hold"
    assert_text "ETF alternatives · Buy"
    assert_page_accessible(label: "portfolio plan with allocation group")
  end

  test "adds multiple groups and lets each group collapse or be removed" do
    prepare_holdings
    second_stock = Instrument.create!(ticker: "ALB2", exchange: "BVMF", name: "Second allocation stock", currency: "BRL", asset_type: :stock)
    User.owner.trades.create!(instrument: second_stock, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 1,
      unit_price: 15, fees_cents: 0, currency: second_stock.currency)
    CurrentMarketPriceCache.new.write(
      instrument: second_stock,
      current_market_price: CurrentMarketPrice.new(
        unit_price: 15, currency: second_stock.currency, provider: "yahoo_finance",
        quoted_at: Time.current - 1.minute, fetched_at: Time.current
      )
    )

    visit portfolio_plan_path
    open_allocation_details("Stock")
    click_on "Add instrument group"
    assert_selector "details[data-controller='allocation-group']", count: 1
    assert_selector "details[data-controller='allocation-group'] > summary:focus", count: 1
    click_on "Add instrument group"
    assert_selector "details[data-controller='allocation-group'] > summary:focus", count: 1

    assert_selector "details[data-controller='allocation-group']", count: 2
    assert_selector "details[data-controller='allocation-group'][open]", count: 2
    groups = all("details[data-controller='allocation-group']")

    groups.first.find("summary").click
    assert_selector "details[data-controller='allocation-group']:not([open])", count: 1
    groups.first.find("summary").click
    assert_selector "details[data-controller='allocation-group'][open]", count: 2

    accept_confirm do
      groups.last.find("button", text: "Delete group").click
    end
    assert_equal groups.first[:id], page.evaluate_script("document.activeElement.closest('details')?.id")
    assert_selector "details[data-controller='allocation-group']", count: 1
  end

  private

  def open_allocation_details(asset_type)
    find("details.portfolio-plan-detail summary", text: asset_type).click
  end

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
