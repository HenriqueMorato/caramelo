class NullifyDeletedCorporateActionsOnImports < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :corporate_action_imports, :corporate_actions
    add_foreign_key :corporate_action_imports, :corporate_actions, on_delete: :nullify
  end
end
