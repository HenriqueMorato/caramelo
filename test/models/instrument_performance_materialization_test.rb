require "test_helper"

class InstrumentPerformanceMaterializationTest < ActiveSupport::TestCase
  setup do
    @user = users(:owner)
    @instrument = instruments(:voo_arcx)
    @state = InstrumentPerformanceMaterialization.for(
      user: @user,
      instrument: @instrument,
      reporting_currency: " usd "
    )
    @from = Date.new(2026, 8, 1)
    @to = Date.new(2026, 8, 31)
  end

  test "reuses one normalized owner instrument and currency scope" do
    assert_equal @state, InstrumentPerformanceMaterialization.for(
      user: @user,
      instrument: @instrument,
      reporting_currency: "USD"
    )
    assert_equal "USD", @state.reporting_currency
    assert_nil @state.requested_range
  end

  test "shares durable range coalescing and generation fencing" do
    @state.request!(from: @from, to: @to)
    @state.request!(from: @from - 1.day, to: @to + 1.day, source_changed: true)

    assert_equal 1, @state.source_generation
    assert_equal (@from - 1.day)..(@to + 1.day), @state.requested_range
    assert_not @state.complete!(source_generation: 0, from: @from - 1.day, to: @to + 1.day)
    assert @state.complete!(source_generation: 1, from: @from - 1.day, to: @to + 1.day)
  end

  test "enforces target uniqueness and valid durable metadata in the database" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      InstrumentPerformanceMaterialization.insert_all!([
        {
          user_id: @user.id,
          instrument_id: @instrument.id,
          reporting_currency: "USD",
          created_at: Time.current,
          updated_at: Time.current
        }
      ])
    end
    assert_raises(ActiveRecord::StatementInvalid) { @state.update_columns(source_generation: -1) }
    assert_raises(ActiveRecord::StatementInvalid) { @state.update_columns(requested_from: @from) }
  end
end
