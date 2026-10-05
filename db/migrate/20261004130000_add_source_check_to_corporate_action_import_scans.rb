class AddSourceCheckToCorporateActionImportScans < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :corporate_action_import_scans,
      "source IN ('yahoo_finance')",
      name: "corporate_action_import_scans_source"
  end
end
