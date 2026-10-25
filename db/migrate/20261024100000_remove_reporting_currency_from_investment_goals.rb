class RemoveReportingCurrencyFromInvestmentGoals < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :investment_goals, name: "investment_goals_reporting_currency_format"
    remove_column :investment_goals, :reporting_currency, :string
  end

  def down
    add_column :investment_goals, :reporting_currency, :string, limit: 3
    execute <<~SQL
      UPDATE investment_goals
      SET reporting_currency = (
        SELECT reporting_currency FROM users WHERE users.id = investment_goals.user_id
      )
    SQL
    change_column_null :investment_goals, :reporting_currency, false
    add_check_constraint :investment_goals,
      "reporting_currency GLOB '[A-Z][A-Z][A-Z]'",
      name: "investment_goals_reporting_currency_format"
  end
end
