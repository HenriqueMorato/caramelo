require "test_helper"

class Position::PresenterTest < ActiveSupport::TestCase
  test "combines a position overview entry with its market price presenter" do
    instrument = instruments(:petr4_bvmf)
    position = Position.for(instrument:)
    entry = Position::OverviewEntry.new(instrument:, position:, error: nil)
    market_price_entry = CurrentMarketPriceCache::Entry.new(current_market_price: nil, status: :missing)
    service = Object.new
    service.define_singleton_method(:read) { |instrument:| market_price_entry }

    presenter = Position::Presenter.for(entry:, market_price_service: service)

    assert_equal entry, presenter.entry
    assert_equal instrument, presenter.instrument
    assert_equal position, presenter.position
    assert_nil presenter.error
    assert_not presenter.invalid?
    assert_predicate presenter, :market_price_refreshable?
    assert_equal instrument, presenter.market_price.instrument
  end

  test "preserves an invalid position entry and an unsupported market price state" do
    instrument = instruments(:voo_arcx)
    error = Position::InvalidLongOnlyData.new(trades(:owner_voo_buy))
    entry = Position::OverviewEntry.new(instrument:, position: nil, error:)
    service = Object.new
    service.define_singleton_method(:read) { |instrument:| nil }

    presenter = Position::Presenter.for(entry:, market_price_service: service)

    assert_predicate presenter, :invalid?
    assert_equal error, presenter.error
    assert_nil presenter.position
    assert_not presenter.market_price_refreshable?
  end
end
