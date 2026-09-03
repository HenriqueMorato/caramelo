require "test_helper"

class PortfolioPerformanceMaterializationTest < ActiveSupport::TestCase
  setup do
    @user = users(:owner)
    @state = PortfolioPerformanceMaterialization.for(user: @user, reporting_currency: " brl ")
    @from = Date.new(2026, 8, 1)
    @to = Date.new(2026, 8, 31)
  end

  test "reuses one normalized owner and currency scope" do
    assert_equal @state, PortfolioPerformanceMaterialization.for(user: @user)
    assert_equal "BRL", @state.reporting_currency
    assert_nil @state.requested_range
  end

  test "coalesces ranges and advances generation only for source changes" do
    @state.request!(from: @from, to: @to)
    @state.request!(from: @from - 1.day, to: @to + 1.day, source_changed: true)
    @state.request!(from: @from + 1.day, to: @to - 1.day)

    assert_equal 1, @state.source_generation
    assert_equal (@from - 1.day)..(@to + 1.day), @state.requested_range
  end

  test "only completes the current generation and the entire requested range" do
    @state.request!(from: @from, to: @to, source_changed: true)

    assert_not @state.complete!(source_generation: 0, from: @from, to: @to)
    assert_not @state.complete!(source_generation: 1, from: @from + 1.day, to: @to)
    assert @state.complete!(source_generation: 1, from: @from, to: @to)
    assert_not_predicate @state, :pending?
    assert_not @state.complete!(source_generation: 1, from: @from, to: @to)
  end

  test "rejects incomplete inverted and future ranges" do
    @state.requested_from = @from
    assert_not_predicate @state, :valid?
    @state.requested_to = @from - 1.day
    assert_not_predicate @state, :valid?

    assert_raises(ArgumentError) { @state.request!(from: @to, to: @from) }
    assert_raises(ArgumentError) { @state.request!(from: @from.to_s, to: @to) }
    assert_raises(ArgumentError) { @state.request!(from: @from, to: Date.current + 1.day) }
  end

  test "database constraints enforce scope uniqueness and valid metadata" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      PortfolioPerformanceMaterialization.insert_all!([
        { user_id: @user.id, reporting_currency: "BRL", created_at: Time.current, updated_at: Time.current }
      ])
    end
    assert_raises(ActiveRecord::StatementInvalid) { @state.update_columns(source_generation: -1) }
    assert_raises(ActiveRecord::StatementInvalid) { @state.update_columns(requested_from: @from) }
  end
end
