class Trade < ApplicationRecord
  extend FriendlyId

  friendly_id :slug_candidates, use: :slugged

  PERFORMANCE_INPUTS = %w[
    user_id instrument_id side traded_on quantity unit_price fees_cents currency
    settlement_currency settlement_exchange_rate
  ].freeze

  belongs_to :user
  belongs_to :instrument
  belongs_to :institution, optional: true

  enum :side, { buy: "buy", sell: "sell" }, validate: true

  monetize :fees_cents, with_model_currency: :currency

  normalizes :currency, with: ->(currency) { currency.strip.upcase }
  normalizes :settlement_currency, with: ->(currency) { currency.strip.upcase.presence }
  normalizes :notes, with: ->(notes) { notes.strip.presence }

  before_validation :synchronize_settlement_currency

  validates :traded_on, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_price, numericality: { greater_than: 0 }
  validates :fees_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, presence: true, iso_currency: true
  validates :settlement_currency, iso_currency: true, allow_nil: true
  validates :settlement_exchange_rate, numericality: { greater_than: 0 }, allow_nil: true
  validate :currency_matches_instrument
  validate :settlement_currency_differs_from_instrument
  validate :institution_belongs_to_user

  after_save :mark_performance_observations_stale, if: :performance_inputs_changed?
  after_destroy :mark_performance_observations_stale
  after_commit :enqueue_performance_observation_rebuild, on: %i[create update destroy]
  after_commit :enqueue_position_materialization_refresh, on: %i[create update destroy]

  scope :reverse_chronological, -> { order(traded_on: :desc, id: :desc) }

  def gross_value_amount
    unit_price * quantity
  end

  def total_amount
    buy? ? gross_value_amount + fees.to_d : gross_value_amount - fees.to_d
  end

  def gross_value
    Money.from_amount(gross_value_amount, currency)
  end

  def total
    Money.from_amount(total_amount, currency)
  end

  def signed_cash_effect
    buy? ? -total : total
  end

  def explicit_settlement_conversion?
    settlement_currency.present? && settlement_exchange_rate.present?
  end

  private

  def slug_candidates
    [ generate_reference_code, generate_reference_code ]
  end

  def generate_reference_code
    "txn-#{SecureRandom.base58(12).downcase}"
  end

  def synchronize_settlement_currency
    if settlement_exchange_rate.present?
      self.settlement_currency = persisted_settlement_currency || user&.reporting_currency
    else
      self.settlement_currency = nil
    end
  end

  def persisted_settlement_currency
    settlement_currency_in_database if persisted?
  end

  def mark_performance_observations_stale
    @performance_invalidation_targets = performance_invalidation_targets
    each_portfolio_performance_target(@performance_invalidation_targets) do |user, from|
      Performance::ObservationInvalidator.mark!(user:, from:)
    end
    each_instrument_performance_target(@performance_invalidation_targets) do |user, instrument, from|
      Performance::ObservationInvalidator.mark_instrument!(user:, instrument:, from:)
    end
  end

  def enqueue_performance_observation_rebuild
    targets = @performance_invalidation_targets
    @performance_invalidation_targets = nil
    return unless targets

    each_portfolio_performance_target(targets) do |user, from|
      Performance::ObservationInvalidator.enqueue(user:, from:)
    end
    each_instrument_performance_target(targets) do |user, instrument, from|
      Performance::ObservationInvalidator.enqueue_instrument(user:, instrument:, from:)
    end
  end

  def enqueue_position_materialization_refresh
    position_materialization_targets.each do |user_id, instrument_id|
      PositionMaterialization.find_by(user_id:, instrument_id:)&.queue_refresh!
      RefreshPositionMaterializationJob.perform_later(user_id:, instrument_id:)
    end
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { trade_id: id })
  end

  def position_materialization_targets
    current = [ user_id, instrument_id ]
    return [ current ] unless saved_change_to_user_id? || saved_change_to_instrument_id?

    previous = [
      saved_change_to_user_id&.first || user_id,
      saved_change_to_instrument_id&.first || instrument_id
    ]
    [ previous, current ].compact.uniq
  end

  def each_portfolio_performance_target(targets)
    dates_by_user = targets.group_by { |(user_id, _instrument_id), _date| user_id }
      .transform_values { |entries| entries.map(&:last).min }
    User.where(id: dates_by_user.keys).each do |user|
      yield user, dates_by_user.fetch(user.id)
    end
  end

  def each_instrument_performance_target(targets)
    users = User.where(id: targets.keys.map(&:first)).index_by(&:id)
    instruments = Instrument.where(id: targets.keys.map(&:last)).index_by(&:id)
    targets.each do |(target_user_id, target_instrument_id), from|
      user = users[target_user_id]
      instrument = instruments[target_instrument_id]
      yield user, instrument, from if user && instrument
    end
  end

  def performance_inputs_changed?
    (saved_changes.keys & PERFORMANCE_INPUTS).any?
  end

  def performance_invalidation_targets
    return { [ user_id, instrument_id ] => traded_on } if destroyed?

    old_user_id, new_user_id = previous_changes.fetch("user_id", [ user_id, user_id ])
    old_instrument_id, new_instrument_id = previous_changes.fetch(
      "instrument_id", [ instrument_id, instrument_id ]
    )
    old_date, new_date = previous_changes.fetch("traded_on", [ traded_on, traded_on ])
    [ [ old_user_id, old_instrument_id, old_date ], [ new_user_id, new_instrument_id, new_date ] ]
      .reject { |target_user_id, target_instrument_id, date| target_user_id.nil? || target_instrument_id.nil? || date.nil? }
      .group_by { |target_user_id, target_instrument_id, _date| [ target_user_id, target_instrument_id ] }
      .transform_values { |targets| targets.map(&:last).min }
  end

  def currency_matches_instrument
    return if currency.blank? || instrument.blank? || currency == instrument.currency

    errors.add(:currency, :instrument_mismatch)
  end

  def settlement_currency_differs_from_instrument
    return if settlement_currency.blank? || currency.blank? || settlement_currency != currency

    errors.add(:settlement_currency, :same_as_instrument)
  end

  def institution_belongs_to_user
    return if institution.blank? || user.blank? || institution.user == user

    errors.add(:institution, :wrong_owner)
  end
end
