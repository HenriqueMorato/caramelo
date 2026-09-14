class AddSlugToTrades < ActiveRecord::Migration[8.1]
  def up
    add_column :trades, :slug, :string

    # Backfill without save callbacks: changing a URL identifier must not enqueue
    # a position or performance rebuild for every historical transaction.
    Trade.reset_column_information
    Trade.find_each do |trade|
      trade.update_columns(slug: available_slug)
    end

    change_column_null :trades, :slug, false
    add_index :trades, :slug, unique: true
  end

  def down
    remove_index :trades, :slug
    remove_column :trades, :slug
  end

  private

  def available_slug
    2.times do
      candidate = "txn-#{SecureRandom.base58(12).downcase}"
      return candidate unless Trade.exists?(slug: candidate)
    end

    "txn-#{SecureRandom.uuid}"
  end
end
