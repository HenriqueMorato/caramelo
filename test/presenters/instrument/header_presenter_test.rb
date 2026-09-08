require "test_helper"

class Instrument::HeaderPresenterTest < ActiveSupport::TestCase
  setup do
    @instrument = instruments(:petr4_bvmf)
    @instrument.daily_closing_prices.delete_all
  end

  test "presents identity, price, and change from the previous close" do
    create_close(price: "30")
    presenter = Instrument::HeaderPresenter.for(
      instrument: @instrument,
      market_price: market_price("31.5")
    )

    assert_equal "PETR", presenter.ticker_mark
    assert_equal "Other", presenter.asset_type_label
    assert_equal "R$31,50", presenter.price_label
    assert_equal "+R$1,50", presenter.day_change_label
    assert_equal "+5.00%", presenter.day_change_ratio_label
    assert_equal "↑", presenter.day_change_arrow
    assert_equal "text-leaf", presenter.day_change_color_class
  end

  test "omits change when a price or previous close is unavailable" do
    presenter = Instrument::HeaderPresenter.for(
      instrument: @instrument,
      market_price: MarketPrice::Presenter.new(instrument: @instrument, lookup: nil)
    )

    assert_nil presenter.price_label
    assert_nil presenter.day_change_label
    assert_nil presenter.day_change_ratio_label
  end

  private

  def create_close(price:)
    DailyClosingPrice.create!(
      instrument: @instrument,
      trading_date: Date.current - 1,
      close_price: price,
      currency: "BRL",
      provider: "yahoo_finance",
      observed_at: Time.current
    )
  end

  def market_price(unit_price)
    current_market_price = CurrentMarketPrice.new(
      unit_price:,
      currency: "BRL",
      provider: "yahoo_finance",
      quoted_at: Time.current,
      fetched_at: Time.current
    )
    lookup = CurrentMarketPriceCache::Lookup.new(current_market_price:, status: :fresh)

    MarketPrice::Presenter.new(instrument: @instrument, lookup:)
  end
end
