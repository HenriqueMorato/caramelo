require "test_helper"

class MarketBenchmarkObservationTest < ActiveSupport::TestCase
  setup do
    MarketBenchmarkObservation.delete_all
    MarketBenchmark.delete_all
    @benchmark = MarketBenchmark.create!(identifier: "IBOV", name: "Ibovespa", kind: "price", currency: "BRL", provider: "BACEN", provider_identifier: "IBOV")
  end

  test "validates an observation in the benchmark currency" do
    observation = @benchmark.observations.new(
      observed_on: Date.current, value: "135000.123456", currency: "BRL", provider: "BACEN", observed_at: Time.current
    )

    assert_predicate observation, :valid?
  end

  test "rejects a mismatched currency" do
    observation = @benchmark.observations.new(
      observed_on: Date.current, value: "135000", currency: "USD", provider: "BACEN", observed_at: Time.current
    )

    assert_not_predicate observation, :valid?
    assert_includes observation.errors[:currency], "is invalid"
  end

  test "rejects a mismatched provider" do
    observation = @benchmark.observations.new(
      observed_on: Date.current, value: "135000", currency: "BRL", provider: "yahoo_finance", observed_at: Time.current
    )

    assert_not_predicate observation, :valid?
    assert_includes observation.errors[:provider], "is invalid"
  end

  test "prevents duplicate provider observations for a date" do
    attributes = { observed_on: Date.current, value: "135000", currency: "BRL", provider: "BACEN", observed_at: Time.current }
    @benchmark.observations.create!(attributes)
    duplicate = @benchmark.observations.new(attributes)

    assert_not_predicate duplicate, :valid?
    assert_includes duplicate.errors[:observed_on], "has already been taken"
  end
end
