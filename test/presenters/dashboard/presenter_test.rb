require "test_helper"

class Dashboard::PresenterTest < ActiveSupport::TestCase
  PositionState = Struct.new(:open?) do
    def closed?
      !open?
    end
  end
  ValuationState = Struct.new(:market_value, :stale?, :missing?) do
    def available?
      market_value.present?
    end
  end
  MarketPriceState = Struct.new(:stale?, :current_market_price)
  PositionStateResult = Struct.new(:invalid?, :position, :valuation, :market_price, :instrument)

  test "summarizes open positions and their market data" do
    fetched_at = Time.current
    value = Money.from_amount(12, Rails.configuration.x.caramelo.reporting_currency)
    position = position_result(
      invalid: false, open: true,
      valuation: ValuationState.new(value, false, false),
      market_price: MarketPriceState.new(false, Struct.new(:fetched_at).new(fetched_at))
    )
    presenter = Dashboard::Presenter.new(positions: [ position ], recent_trades: [], performance: nil)

    assert_equal [ position ], presenter.open_positions
    assert_equal value, presenter.market_value
    assert_equal value, presenter.complete_market_value
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

  test "provides reusable financial display semantics" do
    presenter = Dashboard::Presenter.new(positions: [], recent_trades: [], performance: nil)
    buy = trades(:owner_voo_buy)
    sell = Trade.new(side: :sell)

    assert_equal "+R$10,00", presenter.send(:signed_money, Money.from_amount(10, "BRL"))
    assert_equal "+12.35%", presenter.send(:signed_percentage, BigDecimal("0.123456"))
    assert_equal "↑", presenter.send(:trend_arrow, Money.from_amount(1, "BRL"))
    assert_equal "↓", presenter.send(:trend_arrow, Money.from_amount(-1, "BRL"))
    assert_equal "→", presenter.send(:trend_arrow, Money.from_amount(0, "BRL"))
    assert_equal "text-leaf", presenter.send(:trend_color_class, Money.from_amount(1, "BRL"))
    assert_equal "text-guava", presenter.send(:trend_color_class, Money.from_amount(-1, "BRL"))
    assert_equal "Buy", presenter.trade_side_label(buy)
    assert_equal "Sell", presenter.trade_side_label(sell)
    assert_equal "bg-leaf", presenter.trade_side_color_class(buy)
    assert_equal "bg-guava", presenter.trade_side_color_class(sell)
    assert_nil presenter.send(:signed_money, nil)
    assert_nil presenter.send(:signed_percentage, nil)
    assert_equal "-10.00%", presenter.send(:signed_percentage, BigDecimal("-0.1"))
    assert_nil presenter.send(:trend_arrow, nil)
    assert_equal "text-leaf", presenter.send(:trend_color_class, nil)
    refute presenter.send(:positive?, Object.new)
    refute presenter.send(:negative?, Object.new)
  end

  test "calculates the day change ratio from current and previous values" do
    current_value = Money.from_amount(110, "BRL")
    change = Money.from_amount(10, "BRL")
    presenter_class = Class.new(Dashboard::Presenter) do
      define_method(:market_value) { current_value }
      define_method(:day_change) { change }
    end
    presenter = presenter_class.new(positions: [], recent_trades: [], performance: nil)

    assert_equal BigDecimal("0.1"), presenter.day_change_ratio
    assert_equal "+10.00%", presenter.send(:signed_percentage, presenter.day_change_ratio)
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
    assert_predicate presenter, :market_value_displayable?
    assert_equal Money.from_amount(12, "BRL"), presenter.market_value
    assert_nil presenter.complete_market_value
  end

  test "identifies a partially valued portfolio" do
    available = position_result(
      invalid: false, open: true,
      valuation: ValuationState.new(Money.from_amount(12, "BRL"), false, false),
      market_price: MarketPriceState.new(false, nil)
    )
    missing = position_result(
      invalid: false, open: true,
      valuation: ValuationState.new(nil, false, true),
      market_price: MarketPriceState.new(false, nil)
    )
    presenter = Dashboard::Presenter.new(positions: [ available, missing ], recent_trades: [], performance: nil)

    assert_predicate presenter, :partially_valued?
  end

  test "does not call a portfolio partially valued when every position is unavailable" do
    missing = position_result(
      invalid: false, open: true,
      valuation: ValuationState.new(nil, false, true),
      market_price: MarketPriceState.new(false, nil)
    )
    presenter = Dashboard::Presenter.new(positions: [ missing ], recent_trades: [], performance: nil)

    refute_predicate presenter, :partially_valued?
  end

  test "handles unavailable and zero day-change baselines" do
    presenter = Dashboard::Presenter.new(positions: [], recent_trades: [], performance: nil)

    assert_nil presenter.day_change
    assert_nil presenter.day_change_ratio

    current_value = Money.from_amount(0, "BRL")
    zero_change = Money.from_amount(0, "BRL")
    presenter_class = Class.new(Dashboard::Presenter) do
      define_method(:market_value) { current_value }
      define_method(:day_change) { zero_change }
    end
    zero_presenter = presenter_class.new(positions: [], recent_trades: [], performance: nil)

    assert_nil zero_presenter.day_change_ratio
  end

  test "handles performance availability and missing closing valuation" do
    unavailable = Struct.new(:available?, :closing_valuation).new(false, nil)
    missing_valuation = Struct.new(:available?, :closing_valuation).new(true, nil)
    empty_valuation = Struct.new(:unrealized_gain).new(nil)
    empty_performance = Struct.new(:available?, :closing_valuation).new(true, empty_valuation)
    no_performance = Dashboard::Presenter.new(positions: [], recent_trades: [], performance: nil)
    presenter = Dashboard::Presenter.new(positions: [], recent_trades: [], performance: unavailable)
    missing_presenter = Dashboard::Presenter.new(positions: [], recent_trades: [], performance: missing_valuation)
    empty_presenter = Dashboard::Presenter.new(positions: [], recent_trades: [], performance: empty_performance)

    assert_nil no_performance.unrealized_return
    assert_nil presenter.unrealized_return
    assert_nil missing_presenter.unrealized_return
    assert_nil empty_presenter.unrealized_return
  end

  test "returns an unrealized gain from available performance" do
    valuation = Struct.new(:unrealized_gain).new(Money.from_amount(3, "BRL"))
    performance = Struct.new(:available?, :closing_valuation).new(true, valuation)
    presenter = Dashboard::Presenter.new(positions: [], recent_trades: [], performance:)

    assert_equal valuation.unrealized_gain, presenter.unrealized_return
  end

  test "keeps positions with missing market values in the top list" do
    position = position_result(
      invalid: false, open: true,
      valuation: ValuationState.new(nil, false, true),
      market_price: MarketPriceState.new(false, nil)
    )
    presenter = Dashboard::Presenter.new(positions: [ position ], recent_trades: [], performance: nil)

    assert_equal [ position ], presenter.top_positions
  end

  test "returns no previous value when no closing prices exist" do
    presenter = Dashboard::Presenter.new(positions: [], recent_trades: [], performance: nil)

    assert_nil presenter.send(:previous_business_day_value)
  end

  test "does not expose an unavailable previous valuation" do
    valuation = Struct.new(:available?, :market_value).new(false, Money.from_amount(4, "BRL"))
    presenter_class = Class.new(Dashboard::Presenter) do
      define_method(:previous_business_day_dates) { [ Date.current - 1, Date.current - 2 ] }
      define_method(:previous_portfolio) { |valuation_date:| valuation }
    end
    presenter = presenter_class.new(positions: [], recent_trades: [], performance: nil)

    assert_nil presenter.send(:previous_business_day_value)
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
    assert_equal Money.from_amount(0, Rails.configuration.x.caramelo.reporting_currency), presenter.market_value
    assert_equal Money.from_amount(0, Rails.configuration.x.caramelo.reporting_currency), presenter.complete_market_value
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
