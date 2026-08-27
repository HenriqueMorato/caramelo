require "test_helper"

class MarketPrice::PresenterTest < ActiveSupport::TestCase
  test "presents a supported instrument entry" do
    instrument = instruments(:petr4_bvmf)
    entry = CurrentMarketPriceCache::Entry.new(current_market_price: nil, status: :missing)
    service = Object.new
    service.define_singleton_method(:read) { |instrument:| entry }

    presenter = MarketPrice::Presenter.for(instrument:, service:)

    assert_predicate presenter, :refreshable?
    assert_equal instrument, presenter.instrument
    assert_nil presenter.current_market_price
    assert_not presenter.fresh?
    assert_not presenter.stale?
  end

  test "presents an unsupported instrument as unavailable without refresh" do
    service = Object.new
    service.define_singleton_method(:read) { |instrument:| nil }

    presenter = MarketPrice::Presenter.for(instrument: instruments(:voo_arcx), service:)

    assert_not presenter.refreshable?
    assert_predicate presenter.entry, :missing?
    assert_nil presenter.current_market_price
  end
end
