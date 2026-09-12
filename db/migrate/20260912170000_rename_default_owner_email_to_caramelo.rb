class RenameDefaultOwnerEmailToCaramelo < ActiveRecord::Migration[8.1]
  # Keep this historical migration independent of future User validations and callbacks.
  class UserRecord < ActiveRecord::Base
    self.table_name = "users"
  end

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
    owner = UserRecord.find_by(email_address: from)
    return unless owner

    if UserRecord.exists?(email_address: to)
      raise ActiveRecord::MigrationError, "cannot rename the default owner because #{to} already exists"
    end

    owner.update!(email_address: to)
  end
end
