class CreateCorporateActionImportScans < ActiveRecord::Migration[8.1]
  def change
    create_table :corporate_action_import_scans do |t|
      t.references :user, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.string :source, limit: 64, null: false, default: "yahoo_finance"
      t.string :status, limit: 16, null: false, default: "pending"
      t.date :scanned_through
      t.date :requested_from
      t.date :requested_to
      t.string :run_id, limit: 64
      t.datetime :started_at
      t.datetime :completed_at
      t.text :failure_message

      t.timestamps
    end

    add_index :corporate_action_import_scans,
      %i[user_id instrument_id source],
      unique: true,
      name: "index_corporate_action_import_scans_uniqueness"
    add_index :corporate_action_import_scans,
      %i[user_id status],
      name: "index_corporate_action_import_scans_on_owner_status"
    add_check_constraint :corporate_action_import_scans,
      "status IN ('pending', 'queued', 'running', 'succeeded', 'failed')",
      name: "corporate_action_import_scans_status"
    add_check_constraint :corporate_action_import_scans,
      "(requested_from IS NULL AND requested_to IS NULL) OR " \
        "(requested_from IS NOT NULL AND requested_to IS NOT NULL AND requested_from <= requested_to)",
      name: "corporate_action_import_scans_requested_range"
  end
end
