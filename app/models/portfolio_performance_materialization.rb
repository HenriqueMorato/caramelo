class PortfolioPerformanceMaterialization < ApplicationRecord
  # One owner's derived history in one reporting currency. `source_generation`
  # fences older calculations; the requested bounds coalesce unfinished work
  # and survive cache loss, failed enqueues, and worker restarts.
  belongs_to :user

  normalizes :reporting_currency, with: ->(currency) { currency.strip.upcase }

  validates :reporting_currency, presence: true, iso_currency: true
  validates :source_generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :requested_range_is_complete_and_chronological

  def self.for(user:, reporting_currency: user.reporting_currency)
    find_or_create_by!(user:, reporting_currency: CurrencyCode.normalize(reporting_currency))
  end

  def pending?
    requested_from.present?
  end

  def requested_range
    requested_from..requested_to if pending?
  end

  def request!(from:, to:, source_changed: false)
    validate_requested_range!(from:, to:)

    with_lock do
      update!(
        source_generation: source_generation + (source_changed ? 1 : 0),
        requested_from: [ requested_from, from ].compact.min,
        requested_to: [ requested_to, to ].compact.max
      )
    end
    self
  end

  def complete!(source_generation:, from:, to:)
    completed = false
    with_lock do
      if self.source_generation == source_generation && range_covered_by?(from:, to:)
        update!(requested_from: nil, requested_to: nil)
        completed = true
      end
    end
    completed
  end

  private

  def range_covered_by?(from:, to:)
    pending? && from <= requested_from && to >= requested_to
  end

  def requested_range_is_complete_and_chronological
    if requested_from.present? != requested_to.present?
      errors.add(:base, "requested range must include both boundaries")
    elsif pending? && requested_from > requested_to
      errors.add(:base, "requested range must be chronological")
    end
  end

  def validate_requested_range!(from:, to:)
    return if from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current

    raise ArgumentError, "requested range must use past dates in chronological order"
  end
end
