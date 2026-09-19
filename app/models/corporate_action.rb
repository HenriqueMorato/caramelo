class CorporateAction < ApplicationRecord
  extend FriendlyId

  friendly_id :slug_candidates, use: :slugged

  belongs_to :user
  belongs_to :instrument
  belongs_to :institution, optional: true

  enum :kind, { dividend: "dividend", jcp: "jcp" }, validate: true
  enum :status, {
    pending: "pending", confirmed: "confirmed", ignored: "ignored", reversed: "reversed"
  }, default: :confirmed, validate: true
  attribute :withholding_tax_cents, default: 0

  monetize :gross_amount_cents, with_model_currency: :currency
  monetize :withholding_tax_cents, with_model_currency: :currency
  monetize :net_amount_cents, with_model_currency: :currency

  normalizes :currency, with: ->(currency) { currency.strip.upcase }
  normalizes :source, with: ->(source) { source.strip.downcase }
  normalizes :source_reference, with: ->(reference) { reference.strip.presence }
  normalizes :notes, with: ->(notes) { notes.strip.presence }

  PERFORMANCE_INPUTS = %w[
    user_id instrument_id kind status paid_on ex_date gross_amount_cents
    withholding_tax_cents net_amount_cents currency
  ].freeze

  validates :paid_on, presence: true
  validates :ex_date, comparison: { less_than_or_equal_to: :paid_on }, allow_nil: true
  validates :gross_amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :withholding_tax_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :net_amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, presence: true, iso_currency: true
  validates :source, presence: true, length: { maximum: 64 }
  validates :source_reference, uniqueness: { scope: %i[user_id source instrument_id] }, allow_nil: true
  validate :amounts_reconcile
  validate :currency_matches_instrument
  validate :jcp_requires_brl
  validate :institution_belongs_to_user

  after_save :mark_performance_observations_stale, if: :performance_inputs_changed?
  after_destroy :mark_performance_observations_stale, if: :confirmed?
  after_commit :enqueue_performance_observation_rebuild, on: %i[create update destroy]

  scope :reverse_chronological, -> { order(paid_on: :desc, id: :desc) }
  scope :effective, -> { confirmed }

  def performance_on
    ex_date || paid_on
  end

  private

  def slug_candidates
    [ generate_reference_code, generate_reference_code ]
  end

  def generate_reference_code
    "evt-#{SecureRandom.base58(12).downcase}"
  end

  def amounts_reconcile
    return if gross_amount_cents.nil? || withholding_tax_cents.nil? || net_amount_cents.nil?
    return if net_amount_cents == gross_amount_cents - withholding_tax_cents

    errors.add(:net_amount_cents, :does_not_reconcile)
  end

  def currency_matches_instrument
    return if currency.blank? || instrument.blank? || currency == instrument.currency

    errors.add(:currency, :instrument_mismatch)
  end

  def jcp_requires_brl
    return unless jcp? && currency != "BRL"

    errors.add(:kind, :jcp_requires_brl)
  end

  def institution_belongs_to_user
    return if institution.blank? || user.blank? || institution.user == user

    errors.add(:institution, :wrong_owner)
  end

  def performance_inputs_changed?
    (saved_changes.keys & PERFORMANCE_INPUTS).any?
  end

  def mark_performance_observations_stale
    @performance_invalidation_targets = performance_invalidation_targets
    each_portfolio_performance_target(@performance_invalidation_targets) do |target_user, from|
      Performance::ObservationInvalidator.mark!(user: target_user, from:)
    end
    each_instrument_performance_target(@performance_invalidation_targets) do |target_user, target_instrument, from|
      Performance::ObservationInvalidator.mark_instrument!(
        user: target_user, instrument: target_instrument, from:
      )
    end
  end

  def enqueue_performance_observation_rebuild
    targets = @performance_invalidation_targets
    @performance_invalidation_targets = nil
    return if targets.blank?

    each_portfolio_performance_target(targets) do |target_user, from|
      Performance::ObservationInvalidator.enqueue(user: target_user, from:)
    end
    each_instrument_performance_target(targets) do |target_user, target_instrument, from|
      Performance::ObservationInvalidator.enqueue_instrument(
        user: target_user, instrument: target_instrument, from:
      )
    end
  end

  def performance_invalidation_targets
    targets = destroyed? ? [ current_performance_target ] : []
    targets << previous_performance_target if previously_effective?
    targets << current_performance_target if !destroyed? && confirmed?
    targets.compact.group_by { |target_user_id, target_instrument_id, _date| [ target_user_id, target_instrument_id ] }
      .transform_values { |entries| entries.map(&:last).min }
  end

  def current_performance_target
    [ user_id, instrument_id, performance_on ]
  end

  def previous_performance_target
    previous_user_id = attribute_before_last_save("user_id")
    previous_instrument_id = attribute_before_last_save("instrument_id")
    previous_date = attribute_before_last_save("ex_date") || attribute_before_last_save("paid_on")
    [ previous_user_id, previous_instrument_id, previous_date ]
  end

  def previously_effective?
    !saved_change_to_id? && attribute_before_last_save("status") == "confirmed"
  end

  def each_portfolio_performance_target(targets)
    dates_by_user = targets.group_by { |(target_user_id, _target_instrument_id), _date| target_user_id }
      .transform_values { |entries| entries.map(&:last).min }
    User.where(id: dates_by_user.keys).each do |target_user|
      yield target_user, dates_by_user.fetch(target_user.id)
    end
  end

  def each_instrument_performance_target(targets)
    users = User.where(id: targets.keys.map(&:first)).index_by(&:id)
    instruments = Instrument.where(id: targets.keys.map(&:last)).index_by(&:id)
    targets.each do |(target_user_id, target_instrument_id), from|
      yield users.fetch(target_user_id), instruments.fetch(target_instrument_id), from
    end
  end
end
