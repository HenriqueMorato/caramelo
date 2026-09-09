class Instrument < ApplicationRecord
  has_many :instrument_performance_observations, dependent: :delete_all
  has_many :instrument_performance_materializations, dependent: :delete_all
  has_many :trades, dependent: :restrict_with_error
  has_many :daily_closing_prices, dependent: :restrict_with_error
  has_many :position_materializations, dependent: :delete_all

  enum :asset_type, {
    stock: "stock",
    etf: "etf",
    fund: "fund",
    bond: "bond",
    crypto: "crypto",
    other: "other"
  }, default: :other, validate: true

  normalizes :ticker, with: ->(ticker) { ticker.strip.upcase }
  normalizes :exchange, with: ->(exchange) { exchange.strip.upcase }
  normalizes :name, with: ->(name) { name.strip.squish }
  normalizes :currency, with: ->(currency) { currency.strip.upcase }

  validates :ticker, presence: true, uniqueness: { scope: :exchange, case_sensitive: false }
  validates :exchange, presence: true, format: { with: /\A[A-Z0-9]{4}\z/ }
  validates :name, presence: true
  validates :currency, presence: true, iso_currency: true
  validate :currency_unchanged_when_traded, if: :will_save_change_to_currency?

  scope :alphabetical, -> { order(:ticker, :exchange) }

  private

  def currency_unchanged_when_traded
    return unless persisted? && trades.exists?

    errors.add(:currency, :cannot_change_with_trades)
  end
end
