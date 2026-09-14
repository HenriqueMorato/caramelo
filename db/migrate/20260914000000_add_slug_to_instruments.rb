class AddSlugToInstruments < ActiveRecord::Migration[8.1]
  def up
    add_column :instruments, :slug, :string

    # Use the application model so existing rows follow the same collision rules
    # as newly created instruments; reset its cached schema after adding the column.
    Instrument.reset_column_information
    Instrument.find_each(&:save!)

    change_column_null :instruments, :slug, false
    add_index :instruments, :slug, unique: true
  end

  def down
    remove_index :instruments, :slug
    remove_column :instruments, :slug
  end
end
