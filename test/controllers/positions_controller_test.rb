require "test_helper"

class PositionsControllerTest < ActionDispatch::IntegrationTest
  test "lists open positions derived only from the configured owner's trades" do
    get positions_url

    assert_response :success
    assert_select "h1", "Positions"
    assert_select "h2", text: "VOO"
    assert_select "span", text: "ARCX"
    assert_select "p", text: /Vanguard S&P 500 ETF · USD/
    assert_select "dt", "Average cost"
    assert_select "dt", "Cost basis"
    assert_select "dt", text: "Currency", count: 0
    assert_select "dd", text: "2.5"
    assert_select "dd", text: "$611.60"
    assert_select "dd", text: "$1,529.00"
    assert_select "article", text: /Other owner trade/, count: 0
    assert_select "h2", text: /PETR4/, count: 0
  end

  test "hides closed positions by default and includes them when requested" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 2)
    create_trade(instrument:, side: :sell, quantity: 2, traded_on: Date.new(2026, 1, 2))

    get positions_url

    assert_response :success
    assert_select "h2", text: /PETR4/, count: 0
    assert_select "a[href=?]", positions_path(closed: 1), text: "Include closed positions"

    get positions_url(closed: 1)

    assert_response :success
    assert_select "h2", text: "PETR4"
    assert_select "span", text: "BVMF"
    assert_select "span", "Closed"
    assert_select "a[href=?]", positions_path, text: "Show open positions only"
  end

  test "shows an empty state without owner trades" do
    Trade.where(user: User.owner).delete_all

    get positions_url

    assert_response :success
    assert_select "p", "No positions yet"
    assert_select "a", "Add trade"
  end

  test "identifies an invalid long-only position without failing the page" do
    instrument = instruments(:petr4_bvmf)
    trade = create_trade(instrument:, side: :sell, quantity: 1)

    get positions_url

    assert_response :success
    assert_select "h2", text: "PETR4"
    assert_select "span", text: "BVMF"
    assert_select "span", "Needs attention"
    assert_select "[role='alert']", /Recorded sales exceed purchases on January 01, 2026/
    assert_select "a[href='#{instrument_path(instrument)}']"
    assert_equal trade, Position.overview.find { |entry| entry.instrument == instrument }.error.trade
  end

  private

  def create_trade(instrument:, side:, quantity:, traded_on: Date.new(2026, 1, 1))
    User.owner.trades.create!(
      instrument:,
      side:,
      traded_on:,
      quantity:,
      unit_price: 10,
      fees_cents: 0,
      currency: instrument.currency
    )
  end
end
