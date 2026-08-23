class Instrument < ApplicationRecord
  normalizes :ticker, with: ->(ticker) { ticker.strip.upcase }
  normalizes :exchange, with: ->(exchange) { exchange.strip.upcase }
  normalizes :name, with: ->(name) { name.strip.squish }
  normalizes :currency, with: ->(currency) { currency.strip.upcase }

  validates :ticker, presence: true, uniqueness: { scope: :exchange, case_sensitive: false }
  validates :exchange, presence: true, format: { with: /\A[A-Z0-9]{4}\z/ }
  validates :name, presence: true
  validates :currency, presence: true, iso_currency: true

  scope :alphabetical, -> { order(:ticker, :exchange) }
end
