class CorporateAction < ApplicationRecord
  extend FriendlyId

  RATIO_INTEGER_MAX = (2**63) - 1

  friendly_id :slug_candidates, use: :slugged

  belongs_to :user
  belongs_to :instrument
  belongs_to :institution, optional: true

  enum :kind, {
    dividend: "dividend", jcp: "jcp", stock_split: "split",
    reverse_split: "reverse_split", share_bonus: "share_bonus"
  }, validate: true
  enum :status, {
    pending: "pending", confirmed: "confirmed", ignored: "ignored", reversed: "reversed"
  }, default: :confirmed, validate: true
  attribute :withholding_tax_cents, default: 0
  monetize :gross_amount_cents, with_model_currency: :currency, allow_nil: true
  monetize :withholding_tax_cents, with_model_currency: :currency, allow_nil: true
  monetize :net_amount_cents, with_model_currency: :currency, allow_nil: true
  monetize :cash_in_lieu_amount_cents, with_model_currency: :currency, allow_nil: true
  attr_accessor :cash_in_lieu_amount_input
  attr_writer :bonus_percentage

  normalizes :currency, with: ->(currency) { currency.strip.upcase }
  normalizes :source, with: ->(source) { source.strip.downcase }
  normalizes :source_reference, with: ->(reference) { reference.strip.presence }
  normalizes :notes, with: ->(notes) { notes.strip.presence }

  PERFORMANCE_INPUTS = %w[
    user_id instrument_id kind status paid_on ex_date gross_amount_cents
    withholding_tax_cents net_amount_cents currency effective_on ratio_numerator
    ratio_denominator cash_in_lieu_quantity cash_in_lieu_amount_cents
  ].freeze
  POSITION_INPUTS = %w[
    user_id instrument_id kind status effective_on ratio_numerator ratio_denominator
    cash_in_lieu_quantity cash_in_lieu_amount_cents currency
  ].freeze
  PERFORMANCE_DATE_SQL = "COALESCE(effective_on, ex_date, paid_on)".freeze

  before_validation :default_withholding_tax_for_cash_action
  before_validation :apply_bonus_percentage

  validates :paid_on, presence: true, if: :cash_action?
  validates :paid_on, :ex_date, absence: true, if: :quantity_action?
  validates :ex_date, comparison: { less_than_or_equal_to: :paid_on }, allow_nil: true, if: :cash_action?
  validates :gross_amount_cents, numericality: { only_integer: true, greater_than: 0 }, if: :cash_action?
  validates :withholding_tax_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, if: :cash_action?
  validates :net_amount_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, if: :cash_action?
  validates :gross_amount_cents, :withholding_tax_cents, :net_amount_cents, absence: true, if: :quantity_action?
  validates :currency, presence: true, iso_currency: true, if: :monetary_action?
  validates :currency, absence: true, if: -> { quantity_action? && !cash_in_lieu? }
  validates :effective_on, presence: true, if: :quantity_action?
  validates :effective_on, comparison: { less_than_or_equal_to: -> { Date.current } },
    if: -> { quantity_action? && confirmed? }
  validates :effective_on, :ratio_numerator, :ratio_denominator, :cash_in_lieu_quantity,
    :cash_in_lieu_amount_cents, absence: true, if: :cash_action?
  validates :ratio_numerator, :ratio_denominator,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: RATIO_INTEGER_MAX },
    if: :quantity_action?
  validates :cash_in_lieu_quantity, numericality: { greater_than: 0 }, allow_nil: true
  validates :cash_in_lieu_amount_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :source, presence: true, length: { maximum: 64 }
  validates :source_reference, uniqueness: { scope: %i[user_id source instrument_id] }, allow_nil: true
  validate :amounts_reconcile
  validate :quantity_ratio_matches_kind
  validate :cash_in_lieu_fields_are_paired
  validate :cash_in_lieu_amount_input_is_numeric
  validate :currency_matches_instrument
  validate :jcp_requires_brl
  validate :institution_belongs_to_user

  after_save :mark_performance_observations_stale, if: :performance_inputs_changed?
  after_destroy :mark_performance_observations_stale, if: :confirmed?
  after_commit :enqueue_performance_observation_rebuild, on: %i[create update destroy]
  after_save :capture_position_materialization_targets, if: :position_inputs_changed?
  after_destroy :capture_position_materialization_targets, if: :quantity_action?
  after_commit :enqueue_position_materialization_refresh, on: %i[create update destroy]

  scope :reverse_chronological, -> { order(Arel.sql("#{PERFORMANCE_DATE_SQL} DESC"), id: :desc) }
  scope :effective, -> { confirmed }
  scope :cash_actions, -> { where(kind: %w[dividend jcp]) }
  scope :quantity_actions, -> { where(kind: %w[split reverse_split share_bonus]) }
  scope :effective_on_or_before, ->(date) { effective.where("#{PERFORMANCE_DATE_SQL} <= ?", date) }

  def self.minimum_performance_on
    type_for_attribute("paid_on").cast(minimum(Arel.sql(PERFORMANCE_DATE_SQL)))
  end

  def performance_on
    effective_on || ex_date || paid_on
  end

  def cash_action?
    dividend? || jcp?
  end

  def quantity_action?
    stock_split? || reverse_split? || share_bonus?
  end

  def cash_in_lieu?
    cash_in_lieu_quantity.present? || cash_in_lieu_amount_cents.present?
  end

  def monetary_action?
    cash_action? || cash_in_lieu?
  end

  def quantity_multiplier
    return unless quantity_action? && ratio_numerator.present? && ratio_denominator.present?

    ratio_numerator.to_r / ratio_denominator.to_r
  end

  def bonus_percentage
    return @bonus_percentage unless @bonus_percentage.nil?
    return unless share_bonus? && quantity_multiplier

    ((quantity_multiplier - 1) * 100).to_d(16).to_s("F")
  end

  private

  def apply_bonus_percentage
    return unless share_bonus? && !@bonus_percentage.nil?

    percentage = BigDecimal(@bonus_percentage.to_s)
    raise ArgumentError unless percentage.finite? && percentage.positive? && percentage.exponent.abs <= 18

    multiplier = 1 + percentage.to_r / 100
    raise ArgumentError if [ multiplier.numerator, multiplier.denominator ].any? { |value| value > RATIO_INTEGER_MAX }

    self.ratio_numerator = multiplier.numerator
    self.ratio_denominator = multiplier.denominator
  rescue ArgumentError, TypeError
    self.ratio_numerator = nil
    self.ratio_denominator = nil
    errors.add(:bonus_percentage, :invalid_percentage)
  end

  def slug_candidates
    [ generate_reference_code, generate_reference_code ]
  end

  def generate_reference_code
    "evt-#{SecureRandom.base58(12).downcase}"
  end

  def amounts_reconcile
    return unless cash_action?
    return if gross_amount_cents.nil? || withholding_tax_cents.nil? || net_amount_cents.nil?
    return if net_amount_cents == gross_amount_cents - withholding_tax_cents

    errors.add(:net_amount_cents, :does_not_reconcile)
  end

  def quantity_ratio_matches_kind
    return unless quantity_action? && quantity_multiplier
    return if reverse_split? ? quantity_multiplier < 1 : quantity_multiplier > 1

    errors.add(:ratio_numerator, reverse_split? ? :must_reduce_quantity : :must_increase_quantity)
  end

  def cash_in_lieu_fields_are_paired
    quantity_present = cash_in_lieu_quantity.present?
    amount_present = cash_in_lieu_amount_cents.present? || cash_in_lieu_amount_input.present?
    return if quantity_present == amount_present

    errors.add(:cash_in_lieu_quantity, :must_include_amount)
  end

  def cash_in_lieu_amount_input_is_numeric
    return if cash_in_lieu_amount_input.blank?

    decimal = BigDecimal(cash_in_lieu_amount_input)
    raise ArgumentError unless decimal.finite?
  rescue ArgumentError, TypeError
    errors.add(:cash_in_lieu_amount, :not_a_number)
  end

  def default_withholding_tax_for_cash_action
    self.withholding_tax_cents = 0 if cash_action? && withholding_tax_cents.nil?
    self.withholding_tax_cents = nil if quantity_action? && withholding_tax_cents == 0
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

  def position_inputs_changed?
    (saved_changes.keys & POSITION_INPUTS).any?
  end

  def capture_position_materialization_targets
    targets = []
    targets << [ user_id, instrument_id ] if confirmed? && quantity_action?
    if !destroyed? && !saved_change_to_id? && previously_effective_quantity_action?
      targets << [
        attribute_before_last_save("user_id"),
        attribute_before_last_save("instrument_id")
      ]
    end
    @position_materialization_targets = targets.compact.uniq
  end

  def previously_effective_quantity_action?
    attribute_before_last_save("status") == "confirmed" &&
      %w[split stock_split reverse_split share_bonus].include?(attribute_before_last_save("kind"))
  end

  def enqueue_position_materialization_refresh
    Array(@position_materialization_targets).each do |target_user_id, target_instrument_id|
      PositionMaterialization.find_by(user_id: target_user_id, instrument_id: target_instrument_id)&.queue_refresh!
      RefreshPositionMaterializationJob.perform_later(
        user_id: target_user_id, instrument_id: target_instrument_id
      )
    end
    @position_materialization_targets = nil
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { corporate_action_id: id })
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
    previous_date = attribute_before_last_save("effective_on") ||
      attribute_before_last_save("ex_date") || attribute_before_last_save("paid_on")
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
