class PortfolioPerformanceObservation < ApplicationRecord
  # One generated calendar-day portfolio valuation. Amounts are exact decimal
  # strings cast to BigDecimal; `stale_at` preserves the last result while a
  # source change is rebuilt, and `generated_at` records the successful build.
  # `source_generation` identifies the input generation used for this value.
  # Cash-flow totals retain exact ratios: sum(amount), and sum(amount * date.jd).
  # Their differences reconstruct dated period flows even across missing closes.
  belongs_to :user

  enum :status, { available: "available", empty: "empty", missing: "missing" }, validate: true

  normalizes :reporting_currency, with: ->(currency) { currency.strip.upcase }

  validates :observed_on, :generated_at, presence: true
  validates :reporting_currency, presence: true, iso_currency: true
  validates :source_generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :market_value_amount, :net_cash_flow_amount,
    numericality: true, presence: true, unless: :missing?
  validates :observed_on, uniqueness: { scope: %i[user_id reporting_currency] }

  scope :chronological, -> { order(:observed_on, :id) }
  scope :for_range, ->(from:, to:) { where(observed_on: from..to).chronological }
  scope :stale, -> { where.not(stale_at: nil) }

  def stale?
    stale_at.present?
  end

  def market_value_amount
    deserialize_decimal(super)
  end

  def market_value_amount=(value)
    super(serialize_decimal(value))
  end

  def net_cash_flow_amount
    deserialize_decimal(super)
  end

  def net_cash_flow_amount=(value)
    super(serialize_decimal(value))
  end

  def cash_flow_total
    Rational(super)
  end

  def dated_cash_flow_total
    Rational(super)
  end

  private

  def deserialize_decimal(value)
    BigDecimal(value) if value.present?
  end

  def serialize_decimal(value)
    value&.to_d&.to_s("F")
  end
end
