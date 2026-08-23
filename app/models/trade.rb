class Trade < ApplicationRecord
  belongs_to :user
  belongs_to :instrument
  belongs_to :institution, optional: true

  enum :side, { buy: "buy", sell: "sell" }, validate: true

  monetize :fees_cents, with_model_currency: :currency

  normalizes :currency, with: ->(currency) { currency.strip.upcase }
  normalizes :notes, with: ->(notes) { notes.strip.presence }

  validates :traded_on, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_price, numericality: { greater_than: 0 }
  validates :fees_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, presence: true, iso_currency: true
  validate :currency_matches_instrument
  validate :institution_belongs_to_user

  scope :reverse_chronological, -> { order(traded_on: :desc, id: :desc) }

  def gross_value
    Money.from_amount(unit_price * quantity, currency)
  end

  def total
    buy? ? gross_value + fees : gross_value - fees
  end

  def signed_cash_effect
    buy? ? -total : total
  end

  private

  def currency_matches_instrument
    return if currency.blank? || instrument.blank? || currency == instrument.currency

    errors.add(:currency, "must match the instrument currency")
  end

  def institution_belongs_to_user
    return if institution.blank? || user.blank? || institution.user == user

    errors.add(:institution, "must belong to the trade owner")
  end
end
