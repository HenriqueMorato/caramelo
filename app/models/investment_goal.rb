class InvestmentGoal < ApplicationRecord
  KINDS = { portfolio_value: "portfolio_value" }.freeze
  STATUSES = {
    active: "active",
    paused: "paused",
    achieved: "achieved",
    archived: "archived"
  }.freeze

  belongs_to :user

  enum :kind, KINDS, validate: true
  enum :status, STATUSES, validate: true

  validates :target_amount, presence: true, numericality: { greater_than: 0 }
  validate :target_amount_format
  validate :target_amount_precision
  validate :target_on_valid
  validate :target_on_not_in_past
  before_update :reopen_achieved_goal

  scope :visible, -> { where(status: %i[active achieved]).order(created_at: :desc) }
  scope :manageable, -> { order(target_on: :asc, created_at: :desc) }

  def target_amount
    deserialize_decimal(super)
  end

  def target_amount=(value)
    @target_amount_format_invalid = false
    super(serialize_decimal(value))
  end

  def reporting_currency
    user&.reporting_currency
  end

  def target_value
    Money.from_amount(target_amount, reporting_currency)
  end

  def reset!
    return false unless achieved? || archived?

    update!(status: :active, achieved_at: nil, celebration_seen_at: nil)
  end

  def pause!
    return false unless active?

    update!(status: :paused)
  end

  def resume!
    return false unless paused?

    update!(status: :active)
  end

  def archive!
    return false if archived?

    update!(status: :archived)
  end

  def celebration_pending?
    achieved? && celebration_seen_at.nil?
  end

  private

  def target_on_not_in_past
    return if target_on.blank? || (!new_record? && !will_save_change_to_target_on?) || target_on >= Date.current

    errors.add(:target_on, :past)
  end

  def target_on_valid
    return if target_on.present? || target_on_before_type_cast.blank?

    errors.add(:target_on, :invalid)
  end

  def target_amount_format
    return unless @target_amount_format_invalid

    errors.add(:target_amount, :not_a_number)
  end

  def target_amount_precision
    return if target_amount.blank? || reporting_currency.blank?

    currency = Money::Currency.find(reporting_currency)
    return unless currency

    exponent = currency.exponent
    return if target_amount.scale <= exponent

    errors.add(:target_amount, :currency_precision, precision: exponent)
  end

  def reopen_achieved_goal
    return unless achieved? && will_save_change_to_target_amount?

    self.status = :active
    self.achieved_at = nil
    self.celebration_seen_at = nil
  end

  def deserialize_decimal(value)
    BigDecimal(value) if value.present?
  end

  def serialize_decimal(value)
    return if value.blank?

    string = value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s.strip
    unless string.match?(/\A[+-]?(?:\d+(?:\.\d+)?|\.\d+)\z/)
      @target_amount_format_invalid = true
      return
    end

    BigDecimal(string).to_s("F")
  end
end
