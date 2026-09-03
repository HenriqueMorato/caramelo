class AddPortfolioPerformanceCashFlowTotals < ActiveRecord::Migration[8.1]
  def up
    add_column :portfolio_performance_observations, :cash_flow_total, :text, null: false, default: "0/1"
    add_column :portfolio_performance_observations, :dated_cash_flow_total, :text, null: false, default: "0/1"

    # Older derived rows do not contain the dated flows needed for Dietz returns.
    execute "UPDATE portfolio_performance_observations SET stale_at = CURRENT_TIMESTAMP"
  end

  def down
    remove_column :portfolio_performance_observations, :dated_cash_flow_total
    remove_column :portfolio_performance_observations, :cash_flow_total
  end
end
