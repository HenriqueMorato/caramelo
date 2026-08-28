require "test_helper"

class Position::PresenterTest < ActiveSupport::TestCase
  test "combines a position calculation result with its market price presenter" do
    instrument = instruments(:petr4_bvmf)
    position = Position.for(instrument:)
    position_result = Position::CalculationResult.new(instrument:, position:, error: nil)
    market_price_lookup = CurrentMarketPriceCache::Lookup.new(current_market_price: nil, status: :missing)
    service = Object.new
    service.define_singleton_method(:read) { |instrument:| market_price_lookup }

    presenter = Position::Presenter.for(position_result:, market_price_service: service)

    assert_equal position_result, presenter.position_result
    assert_equal instrument, presenter.instrument
    assert_equal position, presenter.position
    assert_nil presenter.error
    assert_not presenter.invalid?
    assert_predicate presenter, :market_price_refreshable?
    assert_equal instrument, presenter.market_price.instrument
  end

  test "preserves an invalid calculation result and an unsupported market price state" do
    instrument = Instrument.new(ticker: "VWRA", exchange: "XSWX", name: "Vanguard FTSE All-World", currency: "CHF")
    error = Position::InvalidLongOnlyData.new(trades(:owner_voo_buy))
    position_result = Position::CalculationResult.new(instrument:, position: nil, error:)
    service = Object.new
    service.define_singleton_method(:read) { |instrument:| nil }

    presenter = Position::Presenter.for(position_result:, market_price_service: service)

    assert_predicate presenter, :invalid?
    assert_equal error, presenter.error
    assert_nil presenter.position
    assert_not presenter.market_price_refreshable?
  end
end
