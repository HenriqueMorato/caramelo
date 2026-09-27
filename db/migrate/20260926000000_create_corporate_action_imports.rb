class CreateCorporateActionImports < ActiveRecord::Migration[8.1]
  def change
    create_table :corporate_action_imports do |t|
      t.references :user, null: false, foreign_key: true
      t.references :instrument, foreign_key: true
      t.references :institution, foreign_key: true
      t.references :corporate_action, foreign_key: { on_delete: :nullify }
      t.string :source, limit: 64, null: false
      t.string :source_reference, null: false
      t.string :status, null: false, default: "pending"
      t.string :kind, limit: 32
      t.string :provider_symbol, limit: 64
      t.string :provider_exchange, limit: 16
      t.date :event_on
      t.date :paid_on
      t.date :ex_date
      t.text :amount_per_share
      t.integer :gross_amount_cents
      t.integer :withholding_tax_cents
      t.integer :net_amount_cents
      t.string :currency, limit: 3
      t.integer :ratio_numerator
      t.integer :ratio_denominator
      t.text :normalized_data, null: false, default: "{}"
      t.text :raw_payload, null: false, default: "{}"
      t.text :warnings, null: false, default: "[]"
      t.text :failure_message
      t.datetime :reviewed_at
      t.timestamps
    end

    add_index :corporate_action_imports, %i[user_id source source_reference], unique: true,
      name: "index_corporate_action_imports_on_owner_source_reference"
    add_index :corporate_action_imports, %i[user_id status event_on],
      name: "index_corporate_action_imports_on_owner_status_event"
    add_index :corporate_action_imports, %i[user_id instrument_id status],
      name: "index_corporate_action_imports_on_owner_instrument_status"

    add_check_constraint :corporate_action_imports,
      "status IN ('pending', 'ambiguous', 'confirmed', 'ignored', 'failed', 'conflict')",
      name: "corporate_action_imports_status"
    add_check_constraint :corporate_action_imports,
      "kind IS NULL OR kind IN ('dividend', 'jcp', 'split', 'reverse_split', 'share_bonus')",
      name: "corporate_action_imports_kind"
    add_check_constraint :corporate_action_imports,
      "gross_amount_cents IS NULL OR gross_amount_cents > 0",
      name: "corporate_action_imports_gross_positive"
    add_check_constraint :corporate_action_imports,
      "withholding_tax_cents IS NULL OR withholding_tax_cents >= 0",
      name: "corporate_action_imports_tax_nonnegative"
    add_check_constraint :corporate_action_imports,
      "net_amount_cents IS NULL OR net_amount_cents >= 0",
      name: "corporate_action_imports_net_nonnegative"
    add_check_constraint :corporate_action_imports,
      "ratio_numerator IS NULL OR ratio_numerator > 0",
      name: "corporate_action_imports_ratio_numerator_positive"
    add_check_constraint :corporate_action_imports,
      "ratio_denominator IS NULL OR ratio_denominator > 0",
      name: "corporate_action_imports_ratio_denominator_positive"
    add_check_constraint :corporate_action_imports,
      "source_reference <> ''",
      name: "corporate_action_imports_source_reference_present"
  end
end
