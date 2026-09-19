class CreateCorporateActions < ActiveRecord::Migration[8.1]
  def up
    create_table :corporate_actions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.references :institution, foreign_key: true
      t.string :kind, null: false
      t.string :status, default: "confirmed", null: false
      t.date :paid_on
      t.date :ex_date
      t.integer :gross_amount_cents
      t.integer :withholding_tax_cents
      t.integer :net_amount_cents
      t.string :currency, limit: 3
      t.string :source, limit: 64, default: "manual", null: false
      t.string :source_reference
      t.text :raw_payload
      t.text :notes
      t.string :slug, null: false
      t.timestamps
    end

    add_index :corporate_actions, :slug, unique: true
    add_index :corporate_actions, %i[user_id paid_on]
    add_index :corporate_actions, %i[user_id instrument_id paid_on]
    add_index :corporate_actions, %i[source instrument_id source_reference], unique: true,
      where: "source_reference IS NOT NULL"

    add_check_constraint :corporate_actions, "kind IN ('dividend', 'jcp')",
      name: "corporate_actions_kind"
    add_check_constraint :corporate_actions,
      "status IN ('pending', 'confirmed', 'ignored', 'reversed')",
      name: "corporate_actions_status"
    add_check_constraint :corporate_actions,
      "paid_on IS NOT NULL AND gross_amount_cents IS NOT NULL AND withholding_tax_cents IS NOT NULL AND " \
        "net_amount_cents IS NOT NULL AND currency IS NOT NULL",
      name: "corporate_actions_cash_fields_present"
    add_check_constraint :corporate_actions, "kind <> 'jcp' OR currency = 'BRL'",
      name: "corporate_actions_jcp_currency"
    add_check_constraint :corporate_actions, "ex_date IS NULL OR ex_date <= paid_on",
      name: "corporate_actions_ex_date_not_after_payment"
    add_check_constraint :corporate_actions, "gross_amount_cents > 0",
      name: "corporate_actions_gross_positive"
    add_check_constraint :corporate_actions, "withholding_tax_cents >= 0",
      name: "corporate_actions_tax_nonnegative"
    add_check_constraint :corporate_actions, "net_amount_cents >= 0",
      name: "corporate_actions_net_nonnegative"
    add_check_constraint :corporate_actions,
      "net_amount_cents = gross_amount_cents - withholding_tax_cents",
      name: "corporate_actions_amounts_reconcile"
  end

  def down
    drop_table :corporate_actions
  end
end
