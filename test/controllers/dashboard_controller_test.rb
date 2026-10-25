require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  # Requests run through a separate connection, so dashboard records must be
  # committed for the application server to observe them in parallel CI.
  self.use_transactional_tests = false

  teardown do
    Trade.delete_all
    CorporateActionImportScan.delete_all
    DailyClosingPrice.delete_all
    HistoricalDataBackfill.delete_all
    PortfolioPerformanceObservation.delete_all
    PortfolioPerformanceMaterialization.delete_all
    InvestmentGoal.delete_all
  end

  test "renders the public dashboard for the configured owner" do
    Trade.delete_all

    get root_url

    assert_response :success
    assert_select "h1", "Portfolio overview"
    assert_select "h2", "Your portfolio starts with a trade"
    assert_select "a", { text: "Add trade", count: 0 }
    assert_select "footer[aria-label='Project support']"
    assert_select "footer a[href='https://ko-fi.com/henriquemorato']", text: /Support caramelo/
  end

  test "explains when existing trades lack current market data" do
    Trade.where(user: User.owner).delete_all
    Rails.cache.clear
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on: Date.current - 1, quantity: 1, unit_price: "10",
      fees_cents: 0, currency: instrument.currency
    )

    get root_url

    assert_response :success
    assert_select "h2", "Portfolio value is unavailable"
    assert_select "[role='status']", text: /Add or refresh current prices/
  end

  test "identifies missing instruments when only part of the portfolio is valued" do
    Trade.where(user: User.owner).delete_all
    Rails.cache.clear
    petr4 = instruments(:petr4_bvmf)
    voo = instruments(:voo_arcx)
    User.owner.trades.create!(
      instrument: petr4, side: :buy, traded_on: Date.current, quantity: 1, unit_price: "10",
      fees_cents: 0, currency: petr4.currency
    )
    User.owner.trades.create!(
      instrument: voo, side: :buy, traded_on: Date.current, quantity: 1, unit_price: "10",
      fees_cents: 0, currency: voo.currency
    )
    CurrentMarketPriceCache.new.write(
      instrument: petr4,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "12", currency: petr4.currency, provider: "yahoo_finance",
        quoted_at: Time.current, fetched_at: Time.current
      )
    )

    get root_url

    assert_response :success
    assert_select "[role='status']", text: /Some positions need current market data/
    assert_select "a[href=?]", market_data_health_path, text: "Open data health"
  end

  test "shows a closed portfolio without asking for market data" do
    Trade.where(user: User.owner).delete_all
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on: Date.current - 1, quantity: 2, unit_price: "10",
      fees_cents: 0, currency: instrument.currency
    )
    User.owner.trades.create!(
      instrument:, side: :sell, traded_on: Date.current, quantity: 2, unit_price: "12",
      fees_cents: 0, currency: instrument.currency
    )

    get root_url

    assert_response :success
    assert_select "h2", "No open positions"
    assert_select "[role='status']", text: /no current holdings to value/
  end

  test "shows current portfolio value and recent owner activity" do
    Trade.where(user: User.owner).delete_all
    DailyClosingPrice.delete_all
    instrument = instruments(:petr4_bvmf)
    trade = User.owner.trades.create!(
      instrument:, side: :buy, traded_on: Date.current, quantity: 2, unit_price: "10",
      fees_cents: 0, currency: instrument.currency, notes: "Dashboard trade"
    )
    CurrentMarketPriceCache.new.write(
      instrument:,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "12", currency: instrument.currency, provider: "yahoo_finance",
        quoted_at: Time.current, fetched_at: Time.current
      )
    )
    [ 1, 2 ].each do |days_ago|
      DailyClosingPrice.create!(
        instrument:, trading_date: Date.current - days_ago, close_price: "10", currency: instrument.currency,
        provider: "yahoo_finance", observed_at: Time.current
      )
    end

    get root_url

    assert_response :success
    assert_includes response.body, "Total portfolio value"
    assert_includes response.body, "R$24,00"
    assert_includes response.body, "+R$24,00"
    assert_includes response.body, "Holdings"
    assert_not_includes response.body, "Fees:"
    assert_not_includes response.body, "Currency:"
    assert_select "article##{dom_id(trade)}", text: /PETR4/
    assert_not_includes response.body, "Dashboard trade"
    assert_select "a[href=?]", positions_path
    assert_select "a[href=?]", performance_path, text: "View performance"

    patch money_visibility_url, params: { hidden: "true" }
    get root_url

    assert_includes response.body, ApplicationHelper::MONEY_MASK
    refute_includes response.body, "R$24,00"
    refute_includes response.body, "+R$24,00"
  end

  test "shows complete progress and records a reached investment goal" do
    Trade.where(user: User.owner).delete_all
    DailyClosingPrice.delete_all
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on: Date.current, quantity: 2, unit_price: "10",
      fees_cents: 0, currency: instrument.currency
    )
    CurrentMarketPriceCache.new.write(
      instrument:,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "12", currency: instrument.currency, provider: "yahoo_finance",
        quoted_at: Time.current, fetched_at: Time.current
      )
    )
    goal = User.owner.investment_goals.create!(target_amount: "24")
    other_goal = User.owner.investment_goals.create!(target_amount: "48")
    third_goal = User.owner.investment_goals.create!(target_amount: "72")

    get root_url

    assert_response :success
    assert_select "h2", "You reached your milestone"
    assert_select "[role=progressbar][aria-valuenow='100.0']"
    assert_select "[data-controller='goal-celebration']"
    assert_select "canvas.goal-fireworks[aria-hidden='true']"
    assert_select "[role='group'][class*='lg:grid-cols-2']"
    assert_select "[role='group'][class*='xl:grid-cols-3']", count: 0
    assert_select "[role='group'] a", text: "Edit", count: 0
    assert_operator response.body.index("Total portfolio value"), :<, response.body.index("Investment goal")
    assert_predicate goal.reload, :achieved?
    assert_predicate other_goal.reload, :active?
    assert_predicate third_goal.reload, :active?

    post acknowledge_celebration_investment_goal_url(goal), params: { achieved_at: goal.achieved_at.iso8601(6) }
    get root_url

    assert_select "[data-controller='goal-celebration']", count: 0
  end

  test "does not claim progress when the current portfolio value is incomplete" do
    Trade.where(user: User.owner).delete_all
    Rails.cache.clear
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on: Date.current, quantity: 1, unit_price: "10",
      fees_cents: 0, currency: instrument.currency
    )
    goal = User.owner.investment_goals.create!(target_amount: "10")

    get root_url

    assert_response :success
    assert_select "h2", "Your goal is waiting for market data"
    assert_predicate goal.reload, :active?
  end

  test "shows stale progress without claiming the goal" do
    Trade.where(user: User.owner).delete_all
    Rails.cache.clear
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on: Date.current, quantity: 2, unit_price: "10",
      fees_cents: 0, currency: instrument.currency
    )
    CurrentMarketPriceCache.new.write(
      instrument:,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "12", currency: instrument.currency, provider: "yahoo_finance",
        quoted_at: 2.hours.ago, fetched_at: 2.hours.ago
      )
    )
    goal = User.owner.investment_goals.create!(target_amount: "48")

    get root_url

    assert_response :success
    assert_select "[data-goal-state='stale']"
    assert_select "h2", "Your next milestone"
    assert_select "p", text: /last known portfolio value/
    assert_predicate goal.reload, :active?
  end

  test "evaluates a goal in the account reporting currency" do
    Trade.where(user: User.owner).delete_all
    Rails.cache.clear
    User.owner.update!(reporting_currency: "USD")
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on: Date.current, quantity: 2, unit_price: "10",
      fees_cents: 0, currency: instrument.currency
    )
    CurrentMarketPriceCache.new.write(
      instrument:,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "12", currency: instrument.currency, provider: "yahoo_finance",
        quoted_at: Time.current, fetched_at: Time.current
      )
    )
    ExchangeRateCache.new.write(
      exchange_rate: ExchangeRate::Rate.new(
        base_currency: "BRL", quote_currency: "USD", rate: BigDecimal("0.2"),
        observed_at: Time.current, fetched_at: Time.current, provider: "yahoo_finance_fx"
      )
    )
    goal = User.owner.investment_goals.create!(target_amount: "4.80")

    get root_url

    assert_response :success
    assert_predicate goal.reload, :achieved?
    assert_select "h2", "You reached your milestone"
  end

  test "does not claim progress from a stale conversion rate" do
    Trade.where(user: User.owner).delete_all
    Rails.cache.clear
    User.owner.update!(reporting_currency: "USD")
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on: Date.current, quantity: 2, unit_price: "10",
      fees_cents: 0, currency: instrument.currency
    )
    CurrentMarketPriceCache.new.write(
      instrument:,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "12", currency: instrument.currency, provider: "yahoo_finance",
        quoted_at: Time.current, fetched_at: Time.current
      )
    )
    ExchangeRateCache.new.write(
      exchange_rate: ExchangeRate::Rate.new(
        base_currency: "BRL", quote_currency: "USD", rate: BigDecimal("0.2"),
        observed_at: 2.hours.ago, fetched_at: 2.hours.ago, provider: "yahoo_finance_fx"
      )
    )
    goal = User.owner.investment_goals.create!(target_amount: "4.80")

    get root_url

    assert_response :success
    assert_select "[data-goal-state='stale']"
    assert_select "h2", "Your next milestone"
    assert_predicate goal.reload, :active?
  end
end
