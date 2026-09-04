class RefreshPositionMaterializationJob < ApplicationJob
  queue_as :default

  def perform(user_id:, instrument_id:)
    materialization = PositionMaterialization.find_or_create_by!(user_id:, instrument_id:)
    PositionMaterializations::Refresh.call(materialization:)
  end
end
