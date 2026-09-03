class AddReportingCurrencyToUsers < ActiveRecord::Migration[8.1]
  def change
    # Preserve the existing reporting currency for owners upgrading the app.
    add_column :users, :reporting_currency, :string, limit: 3, null: false, default: "BRL"
    add_check_constraint :users, "reporting_currency GLOB '[A-Z][A-Z][A-Z]'",
      name: "users_reporting_currency_format"
  end
end
