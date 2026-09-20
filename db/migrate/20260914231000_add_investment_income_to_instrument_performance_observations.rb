class AddInvestmentIncomeToInstrumentPerformanceObservations < ActiveRecord::Migration[8.1]
  CONSTRAINT_NAME = "instrument_performance_observations_amounts_match_status"

  def up
    add_column :instrument_performance_observations, :investment_income_amount, :text

    # These rows are a replaceable projection. Rebuilding them is safer than
    # presenting historical rows that silently omit cash distributions.
    execute "DELETE FROM instrument_performance_observations"
    remove_check_constraint :instrument_performance_observations, name: CONSTRAINT_NAME
    add_check_constraint :instrument_performance_observations, amounts_match_status,
      name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :instrument_performance_observations, name: CONSTRAINT_NAME, if_exists: true
    remove_column :instrument_performance_observations, :investment_income_amount
    add_check_constraint :instrument_performance_observations, legacy_amounts_match_status,
      name: CONSTRAINT_NAME
  end

  private

  def amounts_match_status
    <<~SQL.squish
      (status = 'missing' AND
        market_value_amount IS NULL AND
        cost_basis_amount IS NULL AND
        realized_gain_amount IS NULL AND
        unrealized_gain_amount IS NULL AND
        net_cash_flow_amount IS NULL AND
        investment_income_amount IS NULL AND
        invested_amount IS NULL) OR
      (status IN ('available', 'empty') AND
        market_value_amount IS NOT NULL AND
        cost_basis_amount IS NOT NULL AND
        realized_gain_amount IS NOT NULL AND
        unrealized_gain_amount IS NOT NULL AND
        net_cash_flow_amount IS NOT NULL AND
        investment_income_amount IS NOT NULL AND
        invested_amount IS NOT NULL)
    SQL
  end

  def legacy_amounts_match_status
    <<~SQL.squish
      (status = 'missing' AND
        market_value_amount IS NULL AND
        cost_basis_amount IS NULL AND
        realized_gain_amount IS NULL AND
        unrealized_gain_amount IS NULL AND
        net_cash_flow_amount IS NULL AND
        invested_amount IS NULL) OR
      (status IN ('available', 'empty') AND
        market_value_amount IS NOT NULL AND
        cost_basis_amount IS NOT NULL AND
        realized_gain_amount IS NOT NULL AND
        unrealized_gain_amount IS NOT NULL AND
        net_cash_flow_amount IS NOT NULL AND
        invested_amount IS NOT NULL)
    SQL
  end
end
