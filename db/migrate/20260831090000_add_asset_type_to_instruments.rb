class AddAssetTypeToInstruments < ActiveRecord::Migration[8.1]
  def up
    add_column :instruments, :asset_type, :string, null: false, default: "other"
    add_index :instruments, :asset_type
    add_check_constraint :instruments, "asset_type IN ('stock', 'etf', 'fund', 'bond', 'crypto', 'other')", name: "instruments_asset_type_check"
  end

  def down
    remove_check_constraint :instruments, name: "instruments_asset_type_check" if check_constraint_exists?(:instruments, name: "instruments_asset_type_check")
    remove_index :instruments, :asset_type
    remove_column :instruments, :asset_type
  end
end
