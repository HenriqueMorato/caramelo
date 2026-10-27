class AddQuantityStepToInstruments < ActiveRecord::Migration[8.1]
  def change
    add_column :instruments, :quantity_step, :decimal, precision: 20, scale: 8,
      null: false, default: 1
    add_check_constraint :instruments, "quantity_step > 0",
      name: "instruments_quantity_step_positive"
  end
end
