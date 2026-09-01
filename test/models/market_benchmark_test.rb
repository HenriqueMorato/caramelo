require "test_helper"

class MarketBenchmarkTest < ActiveSupport::TestCase
  test "normalizes and validates a benchmark definition" do
    benchmark = MarketBenchmark.new(
      identifier: " ibov ", name: "Ibovespa", kind: "price", currency: "brl", provider: " yahoo_finance "
    )

    assert_predicate benchmark, :valid?
    assert_equal "IBOV", benchmark.identifier
    assert_equal "BRL", benchmark.currency
    assert_equal "yahoo_finance", benchmark.provider
  end

  test "requires a supported benchmark kind" do
    benchmark = MarketBenchmark.new(identifier: "CDI", name: "CDI", kind: "cash", currency: "BRL", provider: "BACEN")

    assert_not_predicate benchmark, :valid?
    assert_includes benchmark.errors[:kind], "is not included in the list"
  end
end
