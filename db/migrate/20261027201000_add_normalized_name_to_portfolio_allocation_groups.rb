class AddNormalizedNameToPortfolioAllocationGroups < ActiveRecord::Migration[8.1]
  def up
    add_column :portfolio_allocation_groups, :normalized_name, :string, limit: 80
    execute <<~SQL
      UPDATE portfolio_allocation_groups
      SET normalized_name = lower(trim(name))
    SQL
    change_column_null :portfolio_allocation_groups, :normalized_name, false
    add_index :portfolio_allocation_groups,
      %i[portfolio_allocation_plan_id normalized_name], unique: true,
      name: "index_portfolio_allocation_groups_normalized_uniqueness"
  end

  def down
    remove_index :portfolio_allocation_groups, name: "index_portfolio_allocation_groups_normalized_uniqueness"
    remove_column :portfolio_allocation_groups, :normalized_name
  end
end
