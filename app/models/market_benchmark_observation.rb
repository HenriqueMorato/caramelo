class MarketBenchmarkObservation < ApplicationRecord
  # One dated benchmark point. `value` is an index level for price series or
  # the provider's daily rate value for rate series, kept in `currency`.
  belongs_to :market_benchmark

  normalizes :currency, with: ->(value) { value.strip.upcase }
  normalizes :provider, with: ->(value) { value.strip.downcase }

  validates :observed_on, :value, :currency, :provider, :observed_at, presence: true
  validates :value, numericality: { greater_than: 0 }
  validates :currency, iso_currency: true
  validates :provider, length: { maximum: 64 }
  validates :observed_on, uniqueness: { scope: %i[market_benchmark_id provider] }
  validate :currency_matches_benchmark

  scope :chronological, -> { order(:observed_on, :id) }

  private

  def currency_matches_benchmark
    return unless market_benchmark && currency.present? && market_benchmark.currency != currency

    errors.add(:currency, :invalid)
  end
end
