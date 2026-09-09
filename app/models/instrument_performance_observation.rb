class InstrumentPerformanceObservation < ApplicationRecord
  DECIMAL_ATTRIBUTES = %i[
    market_value_amount cost_basis_amount realized_gain_amount
    unrealized_gain_amount net_cash_flow_amount
  ].freeze

  belongs_to :user
  belongs_to :instrument

  enum :status, { available: "available", empty: "empty", missing: "missing" }, validate: true

  normalizes :reporting_currency, with: ->(currency) { currency.strip.upcase }

  validates :observed_on, :generated_at, presence: true
  validates :reporting_currency, presence: true, iso_currency: true
  validates :source_generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates(*DECIMAL_ATTRIBUTES, numericality: true, presence: true, unless: :missing?)
  validates :observed_on, uniqueness: { scope: %i[user_id instrument_id reporting_currency] }

  scope :chronological, -> { order(:observed_on, :id) }
  scope :for_range, ->(from:, to:) { where(observed_on: from..to).chronological }
  scope :stale, -> { where.not(stale_at: nil) }

  def stale?
    stale_at.present?
  end

  DECIMAL_ATTRIBUTES.each do |attribute|
    define_method(attribute) do
      deserialize_decimal(super())
    end

    define_method(:"#{attribute}=") do |value|
      super(serialize_decimal(value))
    end
  end

  def cash_flow_total
    Rational(super)
  end

  def cash_flow_total=(value)
    super(value.to_r.to_s)
  end

  def dated_cash_flow_total
    Rational(super)
  end

  def dated_cash_flow_total=(value)
    super(value.to_r.to_s)
  end

  private

  def deserialize_decimal(value)
    BigDecimal(value) if value.present?
  end

  def serialize_decimal(value)
    value&.to_d&.to_s("F")
  end
end
