require "application_system_test_case"

class PerformanceTest < ApplicationSystemTestCase
  test "selects a reporting period and shows performance" do
    Trade.where(user: User.owner).delete_all
    from = Date.current - 1.week
    instrument = Instrument.create!(ticker: "SYPR", exchange: "BVMF", name: "System performance stock", currency: "BRL")
    create_trade(instrument:, traded_on: from)
    create_trade(instrument:, traded_on: Date.current)
    create_daily_close(instrument:, date: from, close_price: "10")
    create_daily_close(instrument:, date: Date.current, close_price: "11")

    visit performance_path

    assert_text "Performance"
    assert_text "R$22,00"
    click_on "Week"
    assert_current_path performance_path(period: "week")
    assert_text "20.00%"
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
