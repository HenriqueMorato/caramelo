class CreateAssetTypes < ActiveRecord::Migration[8.1]
  def up
    create_table :asset_types do |t|
      t.string :key, limit: 32, null: false
      t.string :name, limit: 64, null: false
      t.boolean :system, null: false, default: false
      t.timestamps
    end

    add_index :asset_types, :key, unique: true
    add_check_constraint :asset_types, "key <> ''", name: "asset_types_key_present"
    add_check_constraint :asset_types, "name <> ''", name: "asset_types_name_present"

    # Existing instruments keep their stable category key; the registry now owns
    # which keys are available instead of the database limiting them to six values.
    remove_check_constraint :instruments, name: "instruments_asset_type_check"
  end

  def down
    custom_types = select_value("SELECT COUNT(*) FROM asset_types WHERE system = 0").to_i
    raise ActiveRecord::IrreversibleMigration, "custom asset types exist" if custom_types.positive?

    invalid_keys = select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM instruments
      WHERE asset_type NOT IN ('stock', 'etf', 'fund', 'bond', 'crypto', 'other')
    SQL
    raise ActiveRecord::IrreversibleMigration, "instruments use custom asset types" if invalid_keys.positive?

    add_check_constraint :instruments,
      "asset_type IN ('stock', 'etf', 'fund', 'bond', 'crypto', 'other')",
      name: "instruments_asset_type_check"
    drop_table :asset_types
  end
end
