class RenameDefaultOwnerEmailToCaramelo < ActiveRecord::Migration[8.1]
  FROM_EMAIL = "admin@localfolio.com"
  TO_EMAIL = "admin@caramelo.local"

  def up
    rename_owner(from: FROM_EMAIL, to: TO_EMAIL)
  end

  def down
    rename_owner(from: TO_EMAIL, to: FROM_EMAIL)
  end

  private

  def rename_owner(from:, to:)
    return unless select_value("SELECT 1 FROM users WHERE email_address = #{connection.quote(from)} LIMIT 1")

    if select_value("SELECT 1 FROM users WHERE email_address = #{connection.quote(to)} LIMIT 1")
      raise ActiveRecord::MigrationError, "cannot rename the default owner because #{to} already exists"
    end

    execute <<~SQL.squish
      UPDATE users
      SET email_address = #{connection.quote(to)}, updated_at = CURRENT_TIMESTAMP
      WHERE email_address = #{connection.quote(from)}
    SQL
  end
end
