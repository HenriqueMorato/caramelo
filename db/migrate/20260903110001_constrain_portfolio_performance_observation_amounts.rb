class ConstrainPortfolioPerformanceObservationAmounts < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :portfolio_performance_observations,
      "(status = 'missing' AND market_value_amount IS NULL AND net_cash_flow_amount IS NULL) OR " \
        "(status IN ('available', 'empty') AND market_value_amount IS NOT NULL AND net_cash_flow_amount IS NOT NULL)",
      name: "portfolio_performance_observations_amounts_match_status"
  end
end
