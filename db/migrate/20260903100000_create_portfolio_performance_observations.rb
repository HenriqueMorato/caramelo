class CreatePortfolioPerformanceObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :portfolio_performance_observations do |t|
      t.references :user, null: false, foreign_key: true
      t.date :observed_on, null: false
      t.string :reporting_currency, limit: 3, null: false
      # Text affinity prevents SQLite from rounding analytical decimals before
      # Active Record casts them back to BigDecimal.
      t.text :market_value_amount
      t.text :net_cash_flow_amount
      t.string :status, null: false
      t.datetime :generated_at, null: false
      t.datetime :stale_at

      t.timestamps
    end

    add_index :portfolio_performance_observations,
      %i[user_id reporting_currency observed_on],
      unique: true,
      name: "index_portfolio_performance_observations_uniqueness"
    add_check_constraint :portfolio_performance_observations,
      "status IN ('available', 'empty', 'missing')",
      name: "portfolio_performance_observations_status"
  end
end
