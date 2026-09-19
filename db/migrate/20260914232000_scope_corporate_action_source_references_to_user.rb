class ScopeCorporateActionSourceReferencesToUser < ActiveRecord::Migration[8.1]
  OLD_INDEX = "idx_on_source_instrument_id_source_reference_d9d96f9883"
  NEW_INDEX = "index_corporate_actions_on_owner_provider_reference"

  def up
    remove_index :corporate_actions, name: OLD_INDEX
    add_index :corporate_actions, %i[user_id source instrument_id source_reference],
      unique: true, where: "source_reference IS NOT NULL", name: NEW_INDEX
  end

  def down
    remove_index :corporate_actions, name: NEW_INDEX
    add_index :corporate_actions, %i[source instrument_id source_reference],
      unique: true, where: "source_reference IS NOT NULL", name: OLD_INDEX
  end
end
