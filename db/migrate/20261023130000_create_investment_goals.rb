class CreateInvestmentGoals < ActiveRecord::Migration[8.1]
  def change
    create_table :investment_goals do |t|
      t.references :user, null: false, foreign_key: true
      t.string :kind, limit: 32, default: "portfolio_value", null: false
      # Text affinity keeps the target exact on SQLite until it is converted to
      # a BigDecimal by the model.
      t.text :target_amount, null: false
      t.string :reporting_currency, limit: 3, null: false
      t.date :target_on
      t.string :status, limit: 16, default: "active", null: false
      t.datetime :achieved_at
      t.datetime :celebration_seen_at
      t.timestamps
    end

    add_index :investment_goals, %i[user_id status]
    add_index :investment_goals, %i[user_id kind]
    add_check_constraint :investment_goals,
      "kind IN ('portfolio_value')",
      name: "investment_goals_kind"
    add_check_constraint :investment_goals,
      "status IN ('active', 'paused', 'achieved', 'archived')",
      name: "investment_goals_status"
    add_check_constraint :investment_goals,
      "reporting_currency GLOB '[A-Z][A-Z][A-Z]'",
      name: "investment_goals_reporting_currency_format"
  end
end
