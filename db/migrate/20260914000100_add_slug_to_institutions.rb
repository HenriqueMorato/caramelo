class AddSlugToInstitutions < ActiveRecord::Migration[8.1]
  def up
    add_column :institutions, :slug, :string

    # Use the application model so existing rows receive the same readable,
    # collision-safe slugs as institutions created after this migration.
    Institution.reset_column_information
    Institution.find_each(&:save!)

    change_column_null :institutions, :slug, false
    add_index :institutions, :slug, unique: true
  end

  def down
    remove_index :institutions, :slug
    remove_column :institutions, :slug
  end
end
