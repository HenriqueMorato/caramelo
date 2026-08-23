class Instrument < ApplicationRecord
  belongs_to :user

  normalizes :ticker, with: ->(ticker) { ticker.strip.upcase }
  normalizes :name, with: ->(name) { name.strip.squish }
  normalizes :currency, with: ->(currency) { currency.strip.upcase }

  validates :ticker, presence: true, uniqueness: { scope: :user_id, case_sensitive: false }
  validates :name, presence: true
  validates :currency, presence: true, iso_currency: true

  scope :alphabetical, -> { order(:ticker) }
end
