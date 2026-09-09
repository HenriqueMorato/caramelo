class CreateInstrumentPerformanceMaterializationsAndObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :instrument_performance_materializations do |t|
      t.references :user, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.string :reporting_currency, limit: 3, null: false
      t.integer :source_generation, default: 0, null: false
      t.date :requested_from
      t.date :requested_to

      t.timestamps
    end

    add_index :instrument_performance_materializations,
      %i[user_id instrument_id reporting_currency],
      unique: true,
      name: "index_instrument_performance_materializations_uniqueness"
    add_check_constraint :instrument_performance_materializations,
      "source_generation >= 0",
      name: "instrument_performance_materializations_source_generation"
    add_check_constraint :instrument_performance_materializations,
      "(requested_from IS NULL AND requested_to IS NULL) OR " \
        "(requested_from IS NOT NULL AND requested_to IS NOT NULL AND requested_from <= requested_to)",
      name: "instrument_performance_materializations_requested_range"

    create_table :instrument_performance_observations do |t|
      t.references :user, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.date :observed_on, null: false
      t.string :reporting_currency, limit: 3, null: false
      # Text affinity prevents SQLite from rounding analytical decimals before
      # Active Record casts them back to BigDecimal.
      t.text :market_value_amount
      t.text :cost_basis_amount
      t.text :realized_gain_amount
      t.text :unrealized_gain_amount
      t.text :net_cash_flow_amount
      t.text :cash_flow_total, null: false, default: "0/1"
      t.text :dated_cash_flow_total, null: false, default: "0/1"
      t.string :status, null: false
      t.integer :source_generation, default: 0, null: false
      t.datetime :generated_at, null: false
      t.datetime :stale_at

      t.timestamps
    end

    add_index :instrument_performance_observations,
      %i[user_id instrument_id reporting_currency observed_on],
      unique: true,
      name: "index_instrument_performance_observations_uniqueness"
    add_check_constraint :instrument_performance_observations,
      "status IN ('available', 'empty', 'missing')",
      name: "instrument_performance_observations_status"
    add_check_constraint :instrument_performance_observations,
      "source_generation >= 0",
      name: "instrument_performance_observations_source_generation"
    add_check_constraint :instrument_performance_observations,
      <<~SQL.squish,
        (status = 'missing' AND
          market_value_amount IS NULL AND
          cost_basis_amount IS NULL AND
          realized_gain_amount IS NULL AND
          unrealized_gain_amount IS NULL AND
          net_cash_flow_amount IS NULL) OR
        (status IN ('available', 'empty') AND
          market_value_amount IS NOT NULL AND
          cost_basis_amount IS NOT NULL AND
          realized_gain_amount IS NOT NULL AND
          unrealized_gain_amount IS NOT NULL AND
          net_cash_flow_amount IS NOT NULL)
      SQL
      name: "instrument_performance_observations_amounts_match_status"
  end
end
