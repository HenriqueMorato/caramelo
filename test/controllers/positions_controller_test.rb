require "test_helper"

class PositionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  test "lists open positions derived only from the configured owner's trades" do
    get positions_url

    assert_response :success
    assert_select "h1", "Your little pack."
    assert_select "h2", text: "VOO"
    assert_select "span", text: "ARCX"
    assert_select "p", text: /Vanguard S&P 500 ETF · USD/
    assert_select "th", "Average cost"
    assert_select "th", "Cost basis"
    assert_select "th", text: "Currency", count: 0
    assert_select "td", text: "2.5"
    assert_select "td", text: "$611.60"
    assert_select "td", text: "$1,529.00"
    assert_select "article", text: /Other owner trade/, count: 0
    assert_select "h2", text: /PETR4/, count: 0
    assert_select "#current_market_price_instrument_#{instruments(:voo_arcx).id}", text: /Price unavailable/
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

  test "groups positions by type and currency" do
    instruments(:voo_arcx).update!(asset_type: :etf)

    get positions_url(group_by: "asset_type", subgroup_by: "currency")

    assert_response :success
    assert_select "h2[id^='positions-asset_type-']", "ETF"
    assert_select "h3", "USD"
  end

  test "groups positions by their recorded institution" do
    get positions_url(group_by: "institution")

    assert_response :success
    assert_select "h2", "Banco do Brasil"
  end

  test "labels positions with multiple or missing institutions" do
    instrument = instruments(:voo_arcx)
    create_trade(instrument:, side: :buy, quantity: 1)
    User.owner.trades.create!(
      instrument:, institution: institutions(:owner_xp), side: :buy, traded_on: Date.new(2026, 1, 2),
      quantity: 1, unit_price: 10, fees_cents: 0, currency: instrument.currency
    )
    create_trade(instrument: instruments(:petr4_bvmf), side: :buy, quantity: 1)

    get positions_url(group_by: "institution")

    assert_response :success
    assert_select "h2", "Multiple institutions"
    assert_select "h2", "No institution"
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
    assert_equal trade, Position.overview.find { |result| result.instrument == instrument }.error.trade
  end

  test "groups an invalid position by institution without failing the page" do
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(
      instrument:, institution: institutions(:owner_xp), side: :sell, traded_on: Date.new(2026, 1, 1),
      quantity: 1, unit_price: 10, fees_cents: 0, currency: instrument.currency
    )

    get positions_url(group_by: "institution")

    assert_response :success
    assert_select "h2", "XP Investimentos"
    assert_select "[role='alert']", /Recorded sales exceed purchases/
  end

  test "shows the current B3 price and refresh controls" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy, quantity: 1)
    write_current_market_price(instrument:, unit_price: "32.45678901")

    get positions_url

    assert_response :success
    assert_select "#current_market_price_instrument_#{instrument.id}", text: /Current price/
    assert_select "#current_market_price_instrument_#{instrument.id}", text: /R\$32,46/
    assert_select "#current_market_price_instrument_#{instrument.id}", text: /Current/
  end

  test "shows a foreign market value converted to the reporting currency" do
    instrument = instruments(:voo_arcx)
    write_current_market_price(instrument:, unit_price: "100")
    write_exchange_rate(base_currency: "USD", quote_currency: "BRL", rate: "5")

    get positions_url

    assert_response :success
    assert_select "th", "Market value"
    assert_select "td", "R$1.250,00"
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

  def write_current_market_price(instrument:, unit_price:)
    CurrentMarketPriceCache.new.write(
      instrument:,
      current_market_price: CurrentMarketPrice.new(
        unit_price:,
        currency: instrument.currency,
        provider: "yahoo_finance",
        quoted_at: Time.current - 1.minute,
        fetched_at: Time.current
      )
    )
  end

  def write_exchange_rate(base_currency:, quote_currency:, rate:)
    ExchangeRateCache.new.write(
      exchange_rate: ExchangeRate::Rate.new(
        base_currency:, quote_currency:, rate: BigDecimal(rate), observed_at: Time.current,
        fetched_at: Time.current, provider: "yahoo_finance_fx"
      )
    )
  end
end
