require "test_helper"

class PortfolioAllocation::PurchasePlannerTest < ActiveSupport::TestCase
  Instrument = Data.define(:id, :quantity_step)
  Holding = Data.define(:instrument, :price_amount)

  test "returns no purchases when the budget cannot cover a selected unit" do
    candidate = candidate(id: 1, price: "10", gap: "100")

    assert_equal({}, described_class.for(candidates: [ candidate ], budget: BigDecimal("5"), count: 1))
  end

  test "fills a target gap and stops when the remaining budget is exhausted" do
    expensive = candidate(id: 1, price: "80", gap: "85")
    affordable = candidate(id: 2, price: "10", gap: "15")

    result = described_class.for(candidates: [ expensive, affordable ], budget: BigDecimal("100"), count: 2)

    assert_equal BigDecimal("80"), result.fetch(1)
    assert_equal BigDecimal("20"), result.fetch(2)
  end

  test "handles a zero target gap while seeding quantities" do
    funded = candidate(id: 1, price: "1", gap: "100")
    omitted = candidate(id: 2, price: "1", gap: "0")

    result = described_class.for(candidates: [ funded, omitted ], budget: BigDecimal("2"), count: 2)

    assert_equal BigDecimal("1"), result.fetch(1)
    assert_equal BigDecimal("1"), result.fetch(2)
  end

  private

  def described_class
    PortfolioAllocation::PurchasePlanner
  end

  def candidate(id:, price:, gap:, step: "1")
    instrument = Instrument.new(id, BigDecimal(step))
    holding = Holding.new(instrument, BigDecimal(price))
    PortfolioAllocation::PurchasePlanner::Candidate.new(holding, BigDecimal(gap))
  end
end
