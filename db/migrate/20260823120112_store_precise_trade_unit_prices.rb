class StorePreciseTradeUnitPrices < ActiveRecord::Migration[8.1]
  def up
    add_column :trades, :unit_price, :decimal, precision: 28, scale: 8

    select_all("SELECT id, unit_price_cents, currency FROM trades").each do |trade|
      amount = Money.from_cents(trade.fetch("unit_price_cents"), trade.fetch("currency")).to_d
      execute <<~SQL.squish
        UPDATE trades
        SET unit_price = #{connection.quote(amount.to_s("F"))}
        WHERE id = #{connection.quote(trade.fetch("id"))}
      SQL
    end

    change_column_null :trades, :unit_price, false
    remove_check_constraint :trades, name: "trades_unit_price_positive"
    remove_column :trades, :unit_price_cents
    add_check_constraint :trades, "unit_price > 0", name: "trades_unit_price_positive"
  end

  def down
    add_column :trades, :unit_price_cents, :integer

    select_all("SELECT id, unit_price, currency FROM trades").each do |trade|
      cents = Money.from_amount(trade.fetch("unit_price"), trade.fetch("currency")).fractional
      execute <<~SQL.squish
        UPDATE trades
        SET unit_price_cents = #{connection.quote(cents)}
        WHERE id = #{connection.quote(trade.fetch("id"))}
      SQL
    end

    change_column_null :trades, :unit_price_cents, false
    remove_check_constraint :trades, name: "trades_unit_price_positive"
    remove_column :trades, :unit_price
    add_check_constraint :trades, "unit_price_cents > 0", name: "trades_unit_price_positive"
  end
end
