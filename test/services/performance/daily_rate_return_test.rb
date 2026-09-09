require "test_helper"

class Performance::DailyRateReturnTest < ActiveSupport::TestCase
  Observation = Data.define(:observed_on, :value)

  test "compounds rates over an end-exclusive interval with B3 precision" do
    observations = [
      Observation.new(observed_on: Date.new(2026, 1, 2), value: BigDecimal("0.00055131")),
      Observation.new(observed_on: Date.new(2026, 1, 5), value: BigDecimal("0.00051660")),
      Observation.new(observed_on: Date.new(2026, 1, 6), value: BigDecimal("0.00051660"))
    ]

    result = Performance::DailyRateReturn.for(
      observations:, from: Date.new(2026, 1, 2), to: Date.new(2026, 1, 6)
    )

    assert_predicate result, :available?
    assert_equal 2, result.observations.length
    assert_equal BigDecimal("1.00106819"), result.factor
    assert_equal BigDecimal("0.00106819"), result.return_ratio
  end

  test "returns a zero factor for an interval with no rates" do
    result = Performance::DailyRateReturn.for(
      observations: [], from: Date.new(2026, 1, 3), to: Date.new(2026, 1, 4)
    )

    assert_not_predicate result, :available?
    assert_equal BigDecimal("1.00000000"), result.factor
    assert_equal BigDecimal("0.00000000"), result.return_ratio
  end

  test "rejects non-chronological and non-date intervals" do
    assert_raises(ArgumentError) do
      Performance::DailyRateReturn.for(observations: [], from: Date.new(2026, 1, 4), to: Date.new(2026, 1, 4))
    end

    assert_raises(ArgumentError) do
      Performance::DailyRateReturn.for(observations: [], from: "2026-01-01", to: Date.new(2026, 1, 2))
    end
  end
end
