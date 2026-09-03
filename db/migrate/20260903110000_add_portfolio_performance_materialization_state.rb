class AddPortfolioPerformanceMaterializationState < ActiveRecord::Migration[8.1]
  def change
    add_column :portfolio_performance_observations, :source_generation,
      :integer, null: false, default: 0
    add_check_constraint :portfolio_performance_observations,
      "source_generation >= 0",
      name: "portfolio_performance_observations_source_generation"
    create_table :portfolio_performance_materializations do |t|
      t.references :user, null: false, foreign_key: true
      t.string :reporting_currency, limit: 3, null: false
      t.integer :source_generation, null: false, default: 0
      t.date :requested_from
      t.date :requested_to

      t.timestamps
    end

    add_index :portfolio_performance_materializations,
      %i[user_id reporting_currency],
      unique: true,
      name: "index_portfolio_performance_materializations_uniqueness"
    add_check_constraint :portfolio_performance_materializations,
      "source_generation >= 0",
      name: "portfolio_performance_materializations_source_generation"
    add_check_constraint :portfolio_performance_materializations,
      "(requested_from IS NULL AND requested_to IS NULL) OR " \
        "(requested_from IS NOT NULL AND requested_to IS NOT NULL AND requested_from <= requested_to)",
      name: "portfolio_performance_materializations_requested_range"
  end
end
