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
    trades = select_all("SELECT id, unit_price, currency FROM trades").to_a
    subunits_by_trade_id = trades.to_h do |trade|
      subunits = exact_subunits(trade.fetch("unit_price"), trade.fetch("currency"))
      unless subunits
        raise ActiveRecord::IrreversibleMigration,
          "Trade #{trade.fetch("id")} has a unit price that cannot be represented in #{trade.fetch("currency")} subunits"
      end

      [ trade.fetch("id"), subunits ]
    end

    add_column :trades, :unit_price_cents, :integer

    trades.each do |trade|
      execute <<~SQL.squish
        UPDATE trades
        SET unit_price_cents = #{connection.quote(subunits_by_trade_id.fetch(trade.fetch("id")))}
        WHERE id = #{connection.quote(trade.fetch("id"))}
      SQL
    end

    change_column_null :trades, :unit_price_cents, false
    remove_check_constraint :trades, name: "trades_unit_price_positive"
    remove_column :trades, :unit_price
    add_check_constraint :trades, "unit_price_cents > 0", name: "trades_unit_price_positive"
  end

  private

  def exact_subunits(amount, currency)
    subunits = BigDecimal(amount.to_s) * Money::Currency.find(currency).subunit_to_unit
    subunits.to_i if subunits == subunits.to_i
  end
end
