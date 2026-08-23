class CreateInstitutions < ActiveRecord::Migration[8.1]
  def change
    create_table :institutions do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.string :name, null: false, collation: "NOCASE"
      t.text :notes
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :institutions, %i[user_id name], unique: true
  end
end
