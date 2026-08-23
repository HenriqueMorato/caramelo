class CreateInstruments < ActiveRecord::Migration[8.1]
  def change
    create_table :instruments do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.string :ticker, null: false, collation: "NOCASE"
      t.string :name, null: false
      t.string :currency, null: false, default: "BRL"

      t.timestamps
    end

    add_index :instruments, %i[user_id ticker], unique: true
  end
end
