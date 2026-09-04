class Trade < ApplicationRecord
  PERFORMANCE_INPUTS = %w[user_id instrument_id side traded_on quantity unit_price fees_cents currency].freeze

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

  private

  def mark_performance_observations_stale
    @performance_invalidation_targets = performance_invalidation_targets
    each_performance_target(@performance_invalidation_targets) do |user, from|
      Performance::ObservationInvalidator.mark!(user:, from:)
    end
  end

  def enqueue_performance_observation_rebuild
    targets = @performance_invalidation_targets
    @performance_invalidation_targets = nil
    return unless targets

    each_performance_target(targets) do |user, from|
      Performance::ObservationInvalidator.enqueue(user:, from:)
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

  def each_performance_target(targets)
    User.where(id: targets.keys).each do |user|
      yield user, targets.fetch(user.id)
    end
  end

  def performance_inputs_changed?
    (saved_changes.keys & PERFORMANCE_INPUTS).any?
  end

  def performance_invalidation_targets
    return { user_id => traded_on } if destroyed?

    old_user_id, new_user_id = previous_changes.fetch("user_id", [ user_id, user_id ])
    old_date, new_date = previous_changes.fetch("traded_on", [ traded_on, traded_on ])
    [ [ old_user_id, old_date ], [ new_user_id, new_date ] ]
      .reject { |target_user_id, date| target_user_id.nil? || date.nil? }
      .group_by(&:first)
      .transform_values { |targets| targets.map(&:last).min }
  end

  def currency_matches_instrument
    return if currency.blank? || instrument.blank? || currency == instrument.currency

    errors.add(:currency, :instrument_mismatch)
  end

  def institution_belongs_to_user
    return if institution.blank? || user.blank? || institution.user == user

    errors.add(:institution, :wrong_owner)
  end
end
