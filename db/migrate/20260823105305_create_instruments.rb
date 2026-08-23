class CreateInstruments < ActiveRecord::Migration[8.1]
  def change
    create_table :instruments do |t|
      t.string :ticker, null: false, collation: "NOCASE"
      t.string :exchange, null: false, default: "BVMF", collation: "NOCASE"
      t.string :name, null: false
      t.string :currency, null: false, default: "BRL"

      t.timestamps
    end

    add_index :instruments, %i[exchange ticker], unique: true
  end
end
