class HistoricalExchangeRate < ApplicationRecord
  # Provider payload normalized for persistence; one observation represents one
  # currency pair on one market date.
  Observation = Data.define(:base_currency, :quote_currency, :rate_date, :rate, :provider, :observed_at, :fetched_at)

  # Canonical rate returned by a lookup, including metadata from the stored row
  # or nil timestamps for a synthetic same-currency 1:1 rate.
  ResolvedRate = Data.define(:base_currency, :quote_currency, :rate_date, :rate, :provider, :observed_at, :fetched_at)

  # Lookup status distinguishes an available stored rate, an inverse rate, a
  # synthetic same-currency rate, and a genuinely missing historical rate.
  Lookup = Data.define(:exchange_rate, :status, :inverted) do
    def available? = exchange_rate.present?
    def missing? = status == :missing
    def same_currency? = status == :same_currency
  end

  # Import summary lets callers report gaps and distinguish inserts from fixes.
  Result = Data.define(:from, :to, :observations, :missing_dates, :created_count, :updated_count) do
    def missing? = missing_dates.any?
  end

  normalizes :base_currency, :quote_currency, with: ->(currency) { currency.strip.upcase }
  normalizes :provider, with: ->(provider) { provider.strip.downcase }

  validates :base_currency, presence: true, iso_currency: true
  validates :quote_currency, presence: true, iso_currency: true
  validates :rate_date, presence: true
  validates :rate, numericality: { greater_than: 0 }
  validates :provider, presence: true, length: { maximum: 64 }
  validates :observed_at, :fetched_at, presence: true
  validates :rate_date, uniqueness: { scope: %i[base_currency quote_currency provider] }
  validate :currencies_are_distinct

  scope :chronological, -> { order(:rate_date, :id) }

  private

  def currencies_are_distinct
    return if base_currency.blank? || quote_currency.blank? || base_currency != quote_currency

    errors.add(:quote_currency, :invalid)
  end
end
