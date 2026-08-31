require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test "renders the public dashboard for the configured owner" do
    Trade.delete_all

    get root_url

    assert_response :success
    assert_select "h1", "Portfolio overview"
    assert_select "h2", "Your portfolio starts with a trade"
    assert_select "a", { text: "Add trade", count: 0 }
  end

  test "explains when existing trades lack current market data" do
    get root_url

    assert_response :success
    assert_select "h2", "Portfolio value is unavailable"
    assert_select "[role='status']", text: /Add or refresh current prices/
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
    assert_includes response.body, "Market data updated"
    assert_includes response.body, "Holdings"
    assert_not_includes response.body, "Fees:"
    assert_not_includes response.body, "Currency:"
    assert_select "article##{dom_id(trade)}", text: /PETR4/
    assert_not_includes response.body, "Dashboard trade"
    assert_select "a[href=?]", positions_path
    assert_select "a[href=?]", performance_path, text: "View performance"
  end
end
