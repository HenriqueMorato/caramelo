require "test_helper"

class Dashboard::PresenterTest < ActiveSupport::TestCase
  PositionState = Struct.new(:open?) do
    def closed?
      !open?
    end
  end
  ValuationState = Struct.new(:market_value, :stale?, :missing?)
  MarketPriceState = Struct.new(:stale?, :current_market_price)
  PositionStateResult = Struct.new(:invalid?, :position, :valuation, :market_price, :instrument)

  test "summarizes open positions and their market data" do
    fetched_at = Time.current
    value = Money.from_amount(12, Rails.configuration.x.local_folio.reporting_currency)
    position = position_result(
      invalid: false, open: true,
      valuation: ValuationState.new(value, false, false),
      market_price: MarketPriceState.new(false, Struct.new(:fetched_at).new(fetched_at))
    )
    presenter = Dashboard::Presenter.new(positions: [ position ], recent_trades: [], performance: nil)

    assert_equal [ position ], presenter.open_positions
    assert_equal value, presenter.market_value
    assert_predicate presenter, :market_value_available?
    assert_not_predicate presenter, :stale_market_data?
    assert_not_predicate presenter, :missing_market_data?
    assert_equal fetched_at, presenter.last_market_data_at
  end

  test "handles missing and stale positions without presenting a value" do
    stale_position = position_result(
      invalid: false, open: true,
      valuation: ValuationState.new(nil, true, true),
      market_price: MarketPriceState.new(true, nil)
    )
    invalid_position = position_result(
      invalid: true, open: false,
      valuation: ValuationState.new(nil, false, true),
      market_price: MarketPriceState.new(false, nil)
    )
    presenter = Dashboard::Presenter.new(
      positions: [ stale_position, invalid_position ], recent_trades: [], performance: nil
    )

    assert_equal [ stale_position ], presenter.open_positions
    assert_nil presenter.market_value
    assert_not_predicate presenter, :market_value_available?
    assert_predicate presenter, :stale_market_data?
    assert_predicate presenter, :missing_market_data?
    assert_nil presenter.last_market_data_at
  end

  test "orders the dashboard positions by market value and limits them to four" do
    positions = 5.times.map do |index|
      position_result(
        invalid: false, open: true,
        valuation: ValuationState.new(Money.from_amount(index + 1, "BRL"), false, false),
        market_price: MarketPriceState.new(false, nil)
      )
    end
    presenter = Dashboard::Presenter.new(positions:, recent_trades: [], performance: nil)

    assert_equal positions.last(4).reverse, presenter.top_positions
  end

  test "does not present a partial market value as complete" do
    available_position = position_result(
      invalid: false, open: true,
      valuation: ValuationState.new(Money.from_amount(12, "BRL"), false, false),
      market_price: MarketPriceState.new(false, nil)
    )
    missing_position = position_result(
      invalid: false, open: true,
      valuation: ValuationState.new(nil, false, true),
      market_price: MarketPriceState.new(false, nil)
    )
    presenter = Dashboard::Presenter.new(
      positions: [ available_position, missing_position ], recent_trades: [], performance: nil
    )

    assert_not_predicate presenter, :market_value_available?
    assert_nil presenter.market_value
  end

  test "recognizes a fully closed portfolio without requiring market data" do
    closed_position = position_result(
      invalid: false, open: false,
      valuation: ValuationState.new(nil, false, true),
      market_price: MarketPriceState.new(false, nil)
    )
    presenter = Dashboard::Presenter.new(positions: [ closed_position ], recent_trades: [], performance: nil)

    assert_predicate presenter, :no_open_positions?
    assert_not_predicate presenter, :market_value_available?
    assert_equal Money.from_amount(0, Rails.configuration.x.local_folio.reporting_currency), presenter.market_value
  end

  test "returns an empty summary without positions" do
    presenter = Dashboard::Presenter.new(positions: [], recent_trades: [], performance: nil)

    assert_empty presenter.open_positions
    assert_nil presenter.market_value
    assert_not_predicate presenter, :market_value_available?
    assert_not_predicate presenter, :stale_market_data?
    assert_not_predicate presenter, :missing_market_data?
    assert_nil presenter.last_market_data_at
  end

  test "detects a portfolio with trades even when valuation data is missing" do
    position = position_result(
      invalid: false, open: true,
      valuation: ValuationState.new(nil, false, true),
      market_price: MarketPriceState.new(false, nil)
    )
    presenter = Dashboard::Presenter.new(positions: [ position ], recent_trades: [], performance: nil)

    assert_predicate presenter, :has_trades?
  end

  private

  def position_result(invalid:, open:, valuation:, market_price:)
    PositionStateResult.new(invalid, PositionState.new(open), valuation, market_price, instruments(:petr4_bvmf))
  end
end
