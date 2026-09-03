require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  # Requests run through a separate connection, so dashboard records must be
  # committed for the application server to observe them in parallel CI.
  self.use_transactional_tests = false

  teardown do
    Trade.delete_all
    DailyClosingPrice.delete_all
    HistoricalDataBackfill.delete_all
    PortfolioPerformanceObservation.delete_all
    PortfolioPerformanceMaterialization.delete_all
  end

  test "renders the public dashboard for the configured owner" do
    Trade.delete_all

    get root_url

    assert_response :success
    assert_select "h1", "Portfolio overview"
    assert_select "h2", "Your portfolio starts with a trade"
    assert_select "a", { text: "Add trade", count: 0 }
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
  end
end
