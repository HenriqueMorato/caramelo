class CreatePortfolioAllocationPlans < ActiveRecord::Migration[8.1]
  def change
    create_table :portfolio_allocation_plans do |t|
      t.references :user, null: false, foreign_key: true, index: false

      t.timestamps
    end

    add_index :portfolio_allocation_plans, :user_id, unique: true,
      name: "index_portfolio_allocation_plans_on_user_id"

    create_table :portfolio_allocation_asset_targets do |t|
      t.references :portfolio_allocation_plan, null: false, foreign_key: true
      t.string :asset_type_key, limit: 32, null: false
      t.decimal :target_percentage, precision: 20, scale: 8, null: false

      t.timestamps
    end

    add_index :portfolio_allocation_asset_targets,
      %i[portfolio_allocation_plan_id asset_type_key], unique: true,
      name: "index_portfolio_allocation_asset_targets_uniqueness"
    add_foreign_key :portfolio_allocation_asset_targets, :asset_types,
      column: :asset_type_key, primary_key: :key, on_delete: :restrict,
      name: "fk_portfolio_allocation_asset_targets_asset_type"
    add_check_constraint :portfolio_allocation_asset_targets,
      "target_percentage > 0 AND target_percentage <= 100",
      name: "portfolio_allocation_asset_targets_percentage"

    create_table :portfolio_allocation_instrument_targets do |t|
      t.references :portfolio_allocation_plan, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.string :asset_type_key, limit: 32, null: false
      t.decimal :target_percentage, precision: 20, scale: 8, null: false

      t.timestamps
    end

    add_index :portfolio_allocation_instrument_targets,
      %i[portfolio_allocation_plan_id instrument_id], unique: true,
      name: "index_portfolio_allocation_instrument_targets_uniqueness"
    add_foreign_key :portfolio_allocation_instrument_targets, :asset_types,
      column: :asset_type_key, primary_key: :key, on_delete: :restrict,
      name: "fk_portfolio_allocation_instrument_targets_asset_type"
    add_check_constraint :portfolio_allocation_instrument_targets,
      "target_percentage > 0 AND target_percentage <= 100",
      name: "portfolio_allocation_instrument_targets_percentage"
  end
end
