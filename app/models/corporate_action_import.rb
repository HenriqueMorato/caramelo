class CorporateActionImport < ApplicationRecord
  belongs_to :user
  belongs_to :instrument, optional: true
  belongs_to :institution, optional: true
  belongs_to :corporate_action, optional: true

  KINDS = {
    dividend: "dividend", jcp: "jcp", split: "split",
    reverse_split: "reverse_split", share_bonus: "share_bonus"
  }.freeze
  SUPPORTED_KINDS = KINDS.keys.map(&:to_s).freeze

  enum :kind, KINDS, validate: { allow_nil: true }, scopes: false
  enum :status, {
    pending: "pending", ambiguous: "ambiguous", confirmed: "confirmed",
    ignored: "ignored", failed: "failed", conflict: "conflict"
  }, validate: true

  normalizes :source, with: ->(value) { value.to_s.strip.downcase }
  normalizes :source_reference, with: ->(value) { value.to_s.strip.presence }
  normalizes :provider_symbol, with: ->(value) { value.to_s.strip.upcase.presence }
  normalizes :provider_exchange, with: ->(value) { value.to_s.strip.upcase.presence }
  normalizes :currency, with: ->(value) { value.to_s.strip.upcase.presence }
  normalizes :kind, with: ->(value) { value.to_s.strip.downcase.presence }
  normalizes :failure_message, with: ->(value) { value.to_s.strip.presence }

  validates :source, presence: true, length: { maximum: 64 }
  validates :source_reference, presence: true, uniqueness: { scope: %i[user_id source] }
  validates :currency, iso_currency: true, allow_nil: true
  validates :amount_per_share, numericality: { greater_than: 0 }, allow_nil: true
  validates :gross_amount_cents, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :withholding_tax_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :net_amount_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :ratio_numerator, :ratio_denominator,
    numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :owner_matches_associations
  validate :confirmed_import_has_action
  validate :jcp_requires_brl

  scope :reviewable, -> { where(status: %w[pending ambiguous conflict]) }
  scope :reverse_chronological, -> { order(event_on: :desc, created_at: :desc, id: :desc) }

  def self.kinds_for_select
    SUPPORTED_KINDS
  end

  def self.stock_split_kind?(value)
    value.to_s.in?(%w[stock_split split])
  end

  def cash_action?
    dividend? || jcp?
  end

  def quantity_action?
    split? || reverse_split? || share_bonus?
  end

  def reviewable?
    pending? || ambiguous? || conflict?
  end

  def ready_for_confirmation?
    return false unless (pending? || ambiguous?) && instrument && kind.present?
    return false if ambiguous? && institution.blank?

    cash_action? ? paid_on.present? && gross_amount_cents.present? :
      event_on.present? && ratio_numerator.present? && ratio_denominator.present?
  end

  def normalized_candidate
    parse_json(normalized_data, fallback: {})
  end

  def normalized_candidate=(value)
    self.normalized_data = JSON.generate(value || {})
  end

  def normalized_data=(value)
    super(value.is_a?(String) ? value : JSON.generate(value || {}))
  end

  def raw_payload_hash
    parse_json(raw_payload, fallback: {})
  end

  def raw_payload_hash=(value)
    self.raw_payload = JSON.generate(value || {})
  end

  def raw_payload=(value)
    super(value.is_a?(String) ? value : JSON.generate(value || {}))
  end

  def warning_list
    parse_json(warnings, fallback: [])
  end

  def warning_list=(value)
    self.warnings = JSON.generate(Array(value).compact)
  end

  def warnings=(value)
    super(value.is_a?(String) ? value : JSON.generate(Array(value).compact))
  end

  def mark_reviewed!(status:, failure_message: nil)
    update!(status:, failure_message:, reviewed_at: Time.current)
  end

  private

  def parse_json(value, fallback:)
    parsed = JSON.parse(value.presence || (fallback.is_a?(Array) ? "[]" : "{}"))
    parsed.is_a?(fallback.class) ? parsed : fallback
  rescue JSON::ParserError, TypeError
    fallback
  end

  def owner_matches_associations
    return if user.blank?

    errors.add(:institution, :wrong_owner) if institution && institution.user_id != user_id
    errors.add(:corporate_action, :wrong_owner) if corporate_action && corporate_action.user_id != user_id
    if corporate_action && instrument && corporate_action.instrument_id != instrument_id
      errors.add(:corporate_action, :instrument_mismatch)
    end
  end

  def confirmed_import_has_action
    return unless confirmed? && corporate_action_id.blank?

    errors.add(:corporate_action, :required)
  end

  def jcp_requires_brl
    return unless jcp?
    return if instrument&.currency_brl? && (currency.blank? || currency_brl?)

    errors.add(:kind, :jcp_requires_brl)
  end
end
