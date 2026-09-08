require "test_helper"

class DailyClosingPrice::SeriesPresenterTest < ActiveSupport::TestCase
  setup do
    @instrument = instruments(:petr4_bvmf)
    @instrument.daily_closing_prices.delete_all
  end

  test "presents chronological Yahoo closing prices for the chart" do
    create_price(date: Date.current - 2, price: "30.125")
    create_price(date: Date.current - 1, price: "31.5")

    presenter = DailyClosingPrice::SeriesPresenter.for(instrument: @instrument)
    data = presenter.chart_data

    assert_predicate presenter, :available?
    assert_equal [ 30.125, 31.5 ], data.fetch(:values)
    assert_equal [ "R$30,13", "R$31,50" ], data.fetch(:formatted_values)
    assert_equal "BRL", data.fetch(:currency)
    assert_equal [ "R$30,13", "R$31,50" ], presenter.rows.map(&:price)
  end

  test "requires two observations for a useful line chart" do
    create_price(date: Date.current - 1, price: "31.5")

    assert_not DailyClosingPrice::SeriesPresenter.for(instrument: @instrument).available?
  end

  private

  def create_price(date:, price:)
    DailyClosingPrice.create!(
      instrument: @instrument,
      trading_date: date,
      close_price: price,
      currency: @instrument.currency,
      provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier,
      observed_at: Time.current
    )
  end
end
