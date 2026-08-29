require "test_helper"

class PerformancesControllerTest < ActionDispatch::IntegrationTest
  test "shows a selected period with gains from persisted historical data" do
    Trade.where(user: User.owner).delete_all
    from = Date.current - 1.week
    instrument = Instrument.create!(ticker: "PERF", exchange: "BVMF", name: "Performance stock", currency: "BRL")
    create_trade(instrument:, traded_on: from)
    create_trade(instrument:, traded_on: Date.current)
    create_daily_close(instrument:, date: from, close_price: "10")
    create_daily_close(instrument:, date: Date.current, close_price: "11")

    get performance_url(period: "week")

    assert_response :success
    assert_select "h1", "Performance"
    assert_select "a[href=?]", performance_path(period: "week"), "Week"
    assert_select "body", /R\$22,00/
    assert_select "body", /R\$2,00/
    assert_select "body", /20\.00%/
    assert_select "body", /R\$10,00/
  end

  test "shows an explicit unavailable state when historical data is missing" do
    Trade.where(user: User.owner).delete_all
    instrument = Instrument.create!(ticker: "MISS", exchange: "BVMF", name: "Missing stock", currency: "BRL")
    create_trade(instrument:, traded_on: Date.current - 1.month)

    get performance_url

    assert_response :success
    assert_select "h2", "Historical data unavailable"
    assert_select "p", /never substitutes a current quote/
  end

  test "uses the first trade date for the all-time period" do
    Trade.where(user: User.owner).delete_all
    first_trade_date = Date.current - 2.weeks
    instrument = Instrument.create!(ticker: "ALLP", exchange: "BVMF", name: "All-time performance stock", currency: "BRL")
    create_trade(instrument:, traded_on: first_trade_date)
    create_daily_close(instrument:, date: first_trade_date, close_price: "10")
    create_daily_close(instrument:, date: Date.current, close_price: "11")

    get performance_url(period: "all")

    assert_response :success
    assert_select "body", /R\$11,00/
    assert_select "body", /10\.00%/
  end

  test "shows the empty state without owner trades" do
    Trade.where(user: User.owner).delete_all

    get performance_url

    assert_response :success
    assert_select "p", "No performance yet"
    assert_select "a[href=?]", new_trade_path
  end

  private

  def create_trade(instrument:, traded_on:)
    User.owner.trades.create!(
      instrument:, side: :buy, traded_on:, quantity: 1, unit_price: "10", fees_cents: 0, currency: "BRL"
    )
  end

  def create_daily_close(instrument:, date:, close_price:)
    DailyClosingPrice.create!(
      instrument:, trading_date: date, close_price:, currency: "BRL", provider: "yahoo_finance", observed_at: Time.current
    )
  end
end
