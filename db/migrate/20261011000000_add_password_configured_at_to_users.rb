class AddPasswordConfiguredAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :password_configured_at, :datetime
  end
end
