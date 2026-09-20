class AddQuantityFieldsToCorporateActions < ActiveRecord::Migration[8.1]
  CASH_KINDS = "('dividend', 'jcp')"
  QUANTITY_KINDS = "('split', 'reverse_split', 'share_bonus')"

  def up
    add_column :corporate_actions, :effective_on, :date
    add_column :corporate_actions, :ratio_numerator, :integer
    add_column :corporate_actions, :ratio_denominator, :integer
    add_column :corporate_actions, :cash_in_lieu_quantity, :decimal, precision: 28, scale: 12
    add_column :corporate_actions, :cash_in_lieu_amount_cents, :integer

    add_index :corporate_actions, %i[user_id instrument_id effective_on],
      name: "index_corporate_actions_on_owner_instrument_effective_date"

    remove_check_constraint :corporate_actions, name: "corporate_actions_kind"
    remove_check_constraint :corporate_actions, name: "corporate_actions_cash_fields_present"

    add_check_constraint :corporate_actions,
      "kind IN ('dividend', 'jcp', 'split', 'reverse_split', 'share_bonus')",
      name: "corporate_actions_kind"
    add_check_constraint :corporate_actions, subtype_shape_check,
      name: "corporate_actions_subtype_shape"
    add_check_constraint :corporate_actions,
      "ratio_numerator IS NULL OR ratio_numerator > 0",
      name: "corporate_actions_ratio_numerator_positive"
    add_check_constraint :corporate_actions,
      "ratio_denominator IS NULL OR ratio_denominator > 0",
      name: "corporate_actions_ratio_denominator_positive"
    add_check_constraint :corporate_actions,
      "kind NOT IN ('split', 'share_bonus') OR ratio_numerator > ratio_denominator",
      name: "corporate_actions_increasing_ratio"
    add_check_constraint :corporate_actions,
      "kind <> 'reverse_split' OR ratio_numerator < ratio_denominator",
      name: "corporate_actions_decreasing_ratio"
    add_check_constraint :corporate_actions,
      "cash_in_lieu_quantity IS NULL OR cash_in_lieu_quantity > 0",
      name: "corporate_actions_cash_in_lieu_quantity_positive"
    add_check_constraint :corporate_actions,
      "cash_in_lieu_amount_cents IS NULL OR cash_in_lieu_amount_cents >= 0",
      name: "corporate_actions_cash_in_lieu_amount_nonnegative"
  end

  def down
    # The previous schema cannot represent quantity actions. Refuse to discard
    # durable ledger entries during rollback; an empty development rollback is safe.
    if select_value("SELECT 1 FROM corporate_actions WHERE kind IN #{QUANTITY_KINDS} LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "quantity corporate actions must be removed before rollback"
    end

    remove_check_constraint :corporate_actions, name: "corporate_actions_cash_in_lieu_amount_nonnegative"
    remove_check_constraint :corporate_actions, name: "corporate_actions_cash_in_lieu_quantity_positive"
    remove_check_constraint :corporate_actions, name: "corporate_actions_decreasing_ratio"
    remove_check_constraint :corporate_actions, name: "corporate_actions_increasing_ratio"
    remove_check_constraint :corporate_actions, name: "corporate_actions_ratio_denominator_positive"
    remove_check_constraint :corporate_actions, name: "corporate_actions_ratio_numerator_positive"
    remove_check_constraint :corporate_actions, name: "corporate_actions_subtype_shape"
    remove_check_constraint :corporate_actions, name: "corporate_actions_kind"

    add_check_constraint :corporate_actions, "kind IN ('dividend', 'jcp')",
      name: "corporate_actions_kind"
    add_check_constraint :corporate_actions,
      "paid_on IS NOT NULL AND gross_amount_cents IS NOT NULL AND withholding_tax_cents IS NOT NULL AND " \
        "net_amount_cents IS NOT NULL AND currency IS NOT NULL",
      name: "corporate_actions_cash_fields_present"

    remove_index :corporate_actions, name: "index_corporate_actions_on_owner_instrument_effective_date"
    remove_column :corporate_actions, :cash_in_lieu_amount_cents
    remove_column :corporate_actions, :cash_in_lieu_quantity
    remove_column :corporate_actions, :ratio_denominator
    remove_column :corporate_actions, :ratio_numerator
    remove_column :corporate_actions, :effective_on
  end

  private

  def subtype_shape_check
    <<~SQL.squish
      (
        kind IN #{CASH_KINDS}
        AND paid_on IS NOT NULL
        AND gross_amount_cents IS NOT NULL
        AND withholding_tax_cents IS NOT NULL
        AND net_amount_cents IS NOT NULL
        AND currency IS NOT NULL
        AND effective_on IS NULL
        AND ratio_numerator IS NULL
        AND ratio_denominator IS NULL
        AND cash_in_lieu_quantity IS NULL
        AND cash_in_lieu_amount_cents IS NULL
      ) OR (
        kind IN #{QUANTITY_KINDS}
        AND paid_on IS NULL
        AND ex_date IS NULL
        AND gross_amount_cents IS NULL
        AND withholding_tax_cents IS NULL
        AND net_amount_cents IS NULL
        AND effective_on IS NOT NULL
        AND ratio_numerator IS NOT NULL
        AND ratio_denominator IS NOT NULL
        AND (
          (cash_in_lieu_quantity IS NULL AND cash_in_lieu_amount_cents IS NULL AND currency IS NULL)
          OR
          (cash_in_lieu_quantity IS NOT NULL AND cash_in_lieu_amount_cents IS NOT NULL AND currency IS NOT NULL)
        )
      )
    SQL
  end
end
