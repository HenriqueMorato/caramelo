require "test_helper"

class Performance::PresenterTest < ActiveSupport::TestCase
  Result = Struct.new(
    :reporting_cost_basis_amount, :market_value_amount, :realized_gain_amount,
    :unrealized_gain_amount, :return_ratio, :missing, :market_price_as_of
  ) do
    def missing? = missing
    def market_price_as_of = self[:market_price_as_of]
    def exchange_rate_as_of = nil
  end
  PerformanceState = Struct.new(:position_results, :empty, :missing, :valuation_date) do
    def empty? = empty
    def missing? = missing
    def market_value = Money.from_amount(position_results.first.market_value_amount, "BRL")
  end

  test "centralizes formatted gains, return, and trend semantics" do
    presenter = build_presenter(
      Result.new(BigDecimal("100"), BigDecimal("120"), BigDecimal("0"), BigDecimal("20"), BigDecimal("0.2"), false)
    )

    assert_equal Money.from_amount(100, "BRL"), presenter.cost_basis
    assert_equal Money.from_amount(120, "BRL"), presenter.market_value
    assert_equal Money.from_amount(0, "BRL"), presenter.realized_gain
    assert_equal "R$0,00", presenter.realized_gain_label
    assert_not_predicate presenter, :realized_gain?
    assert_equal "+R$20,00", presenter.unrealized_gain_label
    assert_equal "↑", presenter.unrealized_gain_arrow
    assert_equal "text-leaf", presenter.unrealized_gain_color_class
    assert_equal "+20.00%", presenter.return_label
    assert_equal "text-leaf", presenter.return_color_class
    assert_not_predicate presenter, :empty?
    assert_not_predicate presenter, :loading?
    assert_not_predicate presenter, :unavailable?
    assert_equal Date.new(2026, 8, 30), presenter.market_data_as_of
    assert_nil presenter.exchange_rate_as_of
  end

  test "shows a non-zero realized gain" do
    presenter = build_presenter(
      Result.new(BigDecimal("100"), BigDecimal("120"), BigDecimal("5"), BigDecimal("15"), BigDecimal("0.2"), false)
    )

    assert_predicate presenter, :realized_gain?
    assert_equal "+R$5,00", presenter.realized_gain_label
  end

  test "keeps available metrics visible while a backfill is pending" do
    result = Result.new(BigDecimal("100"), BigDecimal("120"), BigDecimal("0"), BigDecimal("20"), BigDecimal("0.2"), false)

    presenter = build_presenter(result, pending: true)

    assert_not_predicate presenter, :loading?
    assert_not_predicate presenter, :unavailable?
  end

  test "uses the negative trend for a loss" do
    presenter = build_presenter(
      Result.new(BigDecimal("100"), BigDecimal("80"), BigDecimal("-5"), BigDecimal("-20"), BigDecimal("-0.2"), false, Date.new(2026, 8, 30))
    )

    assert_predicate presenter, :realized_gain?
    assert_equal "R$-5,00", presenter.realized_gain_label
    assert_equal "↓", presenter.unrealized_gain_arrow
    assert_equal "text-guava", presenter.unrealized_gain_color_class
    assert_equal "-20.00%", presenter.return_label
    assert_equal "text-guava", presenter.return_color_class
  end

  test "exposes empty, loading, and unavailable states" do
    empty = build_presenter(nil, empty: true)
    loading = build_presenter(nil, pending: true)
    unavailable = build_presenter(Result.new(nil, nil, nil, nil, nil, true), missing: true)
    nil_result = build_presenter(nil, missing: true)

    assert_predicate empty, :empty?
    assert_not_predicate empty, :unavailable?
    assert_predicate loading, :loading?
    assert_not_predicate loading, :unavailable?
    assert_predicate unavailable, :unavailable?
    assert_nil unavailable.cost_basis
    assert_nil unavailable.market_value
    assert_nil unavailable.realized_gain
    assert_nil unavailable.unrealized_gain
    assert_nil unavailable.return_ratio
    assert_nil unavailable.unrealized_gain_label
    assert_nil unavailable.return_label
    assert_equal "text-leaf", unavailable.return_color_class
    assert_nil nil_result.cost_basis
    assert_nil nil_result.market_value
    assert_nil nil_result.realized_gain
    assert_nil nil_result.unrealized_gain
    assert_nil nil_result.return_ratio
  end

  private

  def build_presenter(result, empty: false, missing: false, pending: false)
    result = result.dup
    result.market_price_as_of ||= Date.new(2026, 8, 30) if result.respond_to?(:market_price_as_of)
    performance = PerformanceState.new([ result ].compact, empty, missing, Date.new(2026, 8, 31))
    Performance::Presenter.for(performance:, pending:)
  end
end
