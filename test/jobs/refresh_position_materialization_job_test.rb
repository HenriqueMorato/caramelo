require "test_helper"

class RefreshPositionMaterializationJobTest < ActiveJob::TestCase
  test "creates the projection and refreshes it" do
    user = users(:owner)
    instrument = instruments(:petr4_bvmf)

    RefreshPositionMaterializationJob.perform_now(user_id: user.id, instrument_id: instrument.id)

    materialization = PositionMaterialization.find_by!(user:, instrument:)
    assert_predicate materialization, :complete?
  end
end
