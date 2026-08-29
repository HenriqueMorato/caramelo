class DailyClosingPrice < ApplicationRecord
  # `trading_date` identifies the exchange session; `close_price` is the
  # precise closing value in `currency`, supplied by `provider` and recorded
  # at `observed_at`. The database key prevents duplicate provider observations.
  Observation = Data.define(:instrument, :trading_date, :close_price, :currency, :provider, :observed_at)

  # Import results retain the requested range, observations, missing weekdays,
  # and persistence counts so callers can distinguish gaps from corrections.
  Result = Data.define(:from, :to, :observations, :missing_dates, :created_count, :updated_count) do
    def missing? = missing_dates.any?
  end

  belongs_to :instrument

  normalizes :currency, with: ->(currency) { currency.strip.upcase }
  normalizes :provider, with: ->(provider) { provider.strip.downcase }

  validates :trading_date, presence: true
  validates :close_price, numericality: { greater_than: 0 }
  validates :currency, presence: true, iso_currency: true
  validates :provider, presence: true, length: { maximum: 64 }
  validates :observed_at, presence: true
  validates :trading_date, uniqueness: { scope: %i[instrument_id provider] }
  validate :currency_matches_instrument

  scope :chronological, -> { order(:trading_date, :id) }

  private

  def currency_matches_instrument
    return unless instrument && currency.present? && instrument.currency != currency

    errors.add(:currency, :invalid)
  end
end
