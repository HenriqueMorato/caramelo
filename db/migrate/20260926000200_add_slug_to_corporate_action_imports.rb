class AddSlugToCorporateActionImports < ActiveRecord::Migration[8.1]
  def up
    add_column :corporate_action_imports, :slug, :string

    # Backfill without callbacks: imports are replaceable review data and must
    # not trigger confirmation or performance work while gaining URL identifiers.
    CorporateActionImport.reset_column_information
    CorporateActionImport.find_each do |import|
      import.update_columns(slug: available_slug)
    end

    change_column_null :corporate_action_imports, :slug, false
    add_index :corporate_action_imports, :slug, unique: true
  end

  def down
    remove_index :corporate_action_imports, :slug
    remove_column :corporate_action_imports, :slug
  end

  private

  def available_slug
    2.times do
      candidate = "imp-#{SecureRandom.base58(12).downcase}"
      return candidate unless CorporateActionImport.exists?(slug: candidate)
    end

    "imp-#{SecureRandom.uuid}"
  end
end
