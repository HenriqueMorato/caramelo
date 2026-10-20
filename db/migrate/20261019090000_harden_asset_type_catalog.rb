class HardenAssetTypeCatalog < ActiveRecord::Migration[8.1]
  SYSTEM_DEFAULTS = [
    [ "stock", "Stock" ],
    [ "etf", "ETF" ],
    [ "fund", "Fund" ],
    [ "bond", "Bond" ],
    [ "crypto", "Crypto" ],
    [ "other", "Other" ]
  ].freeze

  def up
    add_column :asset_types, :normalized_name, :string, limit: 64
    execute "UPDATE asset_types SET normalized_name = LOWER(name)"
    change_column_null :asset_types, :normalized_name, false
    add_index :asset_types, :normalized_name, unique: true,
      name: "index_asset_types_on_normalized_name"

    seed_system_defaults

    add_foreign_key :instruments, :asset_types,
      column: :asset_type, primary_key: :key, on_delete: :restrict,
      name: "fk_instruments_asset_type"
  end

  def down
    remove_foreign_key :instruments, name: "fk_instruments_asset_type"
    remove_index :asset_types, name: "index_asset_types_on_normalized_name"
    remove_column :asset_types, :normalized_name
  end

  private

  def seed_system_defaults
    timestamp = connection.quote(Time.current)

    SYSTEM_DEFAULTS.each do |key, name|
      execute <<~SQL
        INSERT OR IGNORE INTO asset_types (key, name, normalized_name, system, created_at, updated_at)
        VALUES (#{connection.quote(key)}, #{connection.quote(name)}, #{connection.quote(name.downcase)}, 1, #{timestamp}, #{timestamp})
      SQL
    end
  end
end
