class AddSettlementConversionToTrades < ActiveRecord::Migration[8.1]
  def change
    add_column :trades, :settlement_currency, :string, limit: 3
    add_column :trades, :settlement_exchange_rate, :decimal, precision: 28, scale: 12

    add_check_constraint :trades,
      "settlement_currency IS NULL OR settlement_currency GLOB '[A-Z][A-Z][A-Z]'",
      name: "trades_settlement_currency_format"
    add_check_constraint :trades,
      "settlement_exchange_rate IS NULL OR settlement_exchange_rate > 0",
      name: "trades_settlement_exchange_rate_positive"
    add_check_constraint :trades,
      "(settlement_currency IS NULL) = (settlement_exchange_rate IS NULL)",
      name: "trades_settlement_conversion_complete"
    add_check_constraint :trades,
      "settlement_currency IS NULL OR settlement_currency <> currency",
      name: "trades_settlement_currency_distinct"
  end
end
