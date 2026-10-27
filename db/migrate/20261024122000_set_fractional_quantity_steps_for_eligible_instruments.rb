class SetFractionalQuantityStepsForEligibleInstruments < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE instruments
      SET quantity_step = 0.001,
          updated_at = CURRENT_TIMESTAMP
      WHERE quantity_step = 1
        AND (exchange IN ('ARCX', 'XNAS', 'XNYS') OR LOWER(name) LIKE '%ucits%')
    SQL
  end

  def down
    execute <<~SQL
      UPDATE instruments
      SET quantity_step = 1,
          updated_at = CURRENT_TIMESTAMP
      WHERE quantity_step = 0.001
        AND (exchange IN ('ARCX', 'XNAS', 'XNYS') OR LOWER(name) LIKE '%ucits%')
    SQL
  end
end
