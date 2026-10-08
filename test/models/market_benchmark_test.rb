require "test_helper"

class MarketBenchmarkTest < ActiveSupport::TestCase
  test "ensures each default benchmark exists without overwriting existing definitions" do
    existing = MarketBenchmark.create!(MarketBenchmark::DEFAULTS.first.merge(name: "Custom Ibovespa"))

    MarketBenchmark.ensure_defaults!

    assert_equal "Custom Ibovespa", existing.reload.name
    assert_equal MarketBenchmark::DEFAULTS.map { |attributes| attributes.fetch(:identifier) }.sort,
      MarketBenchmark.order(:identifier).pluck(:identifier).sort
  end

  test "normalizes and validates a benchmark definition" do
    benchmark = MarketBenchmark.new(
      identifier: " test_ibov ", name: "Ibovespa", kind: "price", currency: "brl", provider: " yahoo_finance ", provider_identifier: "^BVSP"
    )

    assert_predicate benchmark, :valid?
    assert_equal "TEST_IBOV", benchmark.identifier
    assert_equal "BRL", benchmark.currency
    assert_equal "yahoo_finance", benchmark.provider
  end

  test "requires a supported benchmark kind" do
    benchmark = MarketBenchmark.new(identifier: "CDI", name: "CDI", kind: "cash", currency: "BRL", provider: "BACEN", provider_identifier: "CDI")

    assert_not_predicate benchmark, :valid?
    assert_includes benchmark.errors[:kind], "is not included in the list"
  end

  test "identifies price and rate benchmarks" do
    price = MarketBenchmark.new(kind: "price")
    total_return = MarketBenchmark.new(kind: "total_return")
    rate = MarketBenchmark.new(kind: "rate")

    assert_predicate price, :price?
    assert_predicate price, :index?
    assert_predicate total_return, :total_return?
    assert_predicate total_return, :index?
    assert_not_predicate price, :rate?
    assert_predicate rate, :rate?
    assert_not_predicate rate, :price?
    assert_not_predicate rate, :index?
  end

  test "requires a gross or net convention for total-return benchmarks" do
    benchmark = MarketBenchmark.new(
      identifier: "ACWI", name: "Global", kind: "total_return", currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^664204-USD-NETR"
    )

    assert_not_predicate benchmark, :valid?
    assert_includes benchmark.errors[:return_convention], "can't be blank"

    benchmark.return_convention = "net"

    assert_predicate benchmark, :valid?
  end

  test "does not attach a return convention to a price or rate benchmark" do
    benchmark = MarketBenchmark.new(
      identifier: "SP500", name: "S&P 500", kind: "price", currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^GSPC", return_convention: "net"
    )

    assert_not_predicate benchmark, :valid?
    assert_includes benchmark.errors[:return_convention], "is invalid"
  end
end
