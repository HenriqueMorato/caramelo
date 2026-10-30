class CreatePortfolioAllocationGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :portfolio_allocation_groups do |t|
      t.references :portfolio_allocation_plan, null: false, foreign_key: true
      t.string :name, limit: 80, null: false
      t.string :asset_type_key, limit: 32, null: false
      t.decimal :target_percentage, precision: 20, scale: 8, null: false

      t.timestamps
    end

    add_index :portfolio_allocation_groups,
      %i[portfolio_allocation_plan_id name], unique: true,
      name: "index_portfolio_allocation_groups_uniqueness"
    add_foreign_key :portfolio_allocation_groups, :asset_types,
      column: :asset_type_key, primary_key: :key, on_delete: :restrict,
      name: "fk_portfolio_allocation_groups_asset_type"
    add_check_constraint :portfolio_allocation_groups,
      "target_percentage > 0 AND target_percentage <= 100",
      name: "portfolio_allocation_groups_percentage"

    create_table :portfolio_allocation_group_members do |t|
      t.references :portfolio_allocation_group, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.string :purchase_policy, limit: 16, null: false, default: "buy"

      t.timestamps
    end

    add_index :portfolio_allocation_group_members,
      %i[portfolio_allocation_group_id instrument_id], unique: true,
      name: "index_portfolio_allocation_group_members_uniqueness"
    add_check_constraint :portfolio_allocation_group_members,
      "purchase_policy IN ('buy', 'hold')",
      name: "portfolio_allocation_group_members_purchase_policy"
  end
end
