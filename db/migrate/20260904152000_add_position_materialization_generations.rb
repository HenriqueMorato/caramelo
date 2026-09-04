class AddPositionMaterializationGenerations < ActiveRecord::Migration[8.1]
  def change
    add_column :position_materializations, :source_generation, :integer, null: false, default: 0
    add_column :position_materializations, :calculated_generation, :integer
    add_check_constraint :position_materializations, "source_generation >= 0",
      name: "position_materializations_source_generation"
  end
end
