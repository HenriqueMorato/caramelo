class AddPositionMaterializationWatermark < ActiveRecord::Migration[8.1]
  def change
    add_column :position_materializations, :source_trade_updated_at, :datetime
  end
end
