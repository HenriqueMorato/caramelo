class CorporateActionImportScan < ApplicationRecord
  ACTIVE_TIMEOUT = 30.minutes

  Request = Data.define(:id, :run_id, :from, :to)

  belongs_to :user
  belongs_to :instrument

  enum :status, {
    pending: "pending", queued: "queued", running: "running", succeeded: "succeeded", failed: "failed"
  }, validate: true

  normalizes :source, with: ->(value) { value.to_s.strip.downcase }
  normalizes :failure_message, with: ->(value) { value.to_s.strip.presence }

  validates :source, presence: true, length: { maximum: 64 }, inclusion: { in: CorporateActionImports::Providers::SUPPORTED_SOURCES }
  validates :instrument, uniqueness: { scope: %i[user_id source] }
  validate :requested_range_is_complete_and_chronological

  scope :for_source, ->(source) { where(source: source.to_s.strip.downcase) }

  def self.for(user:, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE)
    find_or_create_by!(user:, instrument:, source:)
  end

  def active?
    queued? || running?
  end

  def active_expired?(at: Time.current)
    return false unless active?

    active_since = started_at || updated_at || created_at
    active_since && active_since < at - ACTIVE_TIMEOUT
  end

  def requested_range
    requested_from..requested_to if requested_from.present?
  end

  def current_run?(candidate_run_id)
    active? && run_id.present? && run_id == candidate_run_id.to_s
  end

  def with_current_run(candidate_run_id)
    # Keep the generation check and derived-import write under the same row lock
    # used by claim!/rewind!, so a superseding run cannot interleave a write.
    with_lock do
      return false unless current_run?(candidate_run_id)

      yield
    end
  end

  def claim!(from:, to:)
    validate_requested_range!(from:, to:)
    request = nil

    with_lock do
      next if active? && !active_expired?

      if active?
        update!(
          status: :failed,
          run_id: nil,
          completed_at: Time.current,
          failure_message: "Automatic scan lease expired before completion."
        )
      end

      candidate_run_id = SecureRandom.uuid
      update!(
        status: :queued,
        requested_from: from,
        requested_to: to,
        run_id: candidate_run_id,
        started_at: nil,
        completed_at: nil,
        failure_message: nil
      )
      request = Request.new(id:, run_id: candidate_run_id, from:, to:)
    end

    request
  end

  def start!(candidate_run_id)
    with_lock do
      return false unless current_run?(candidate_run_id)

      update!(status: :running, started_at: started_at || Time.current, completed_at: nil)
      true
    end
  end

  def complete!(candidate_run_id, through:)
    validate_requested_range!(from: through, to: through)
    with_lock do
      return false unless current_run?(candidate_run_id)

      update!(
        status: :succeeded,
        scanned_through: [ scanned_through, through ].compact.max,
        requested_from: nil,
        requested_to: nil,
        run_id: nil,
        started_at: nil,
        completed_at: Time.current,
        failure_message: nil
      )
      true
    end
  end

  def rewind!(from:)
    validate_requested_range!(from:, to: from)
    with_lock do
      rewound_through = [ scanned_through, from - 1.day ].compact.min
      changed = status != "pending" || scanned_through != rewound_through || requested_from.present? ||
        requested_to.present? || run_id.present? || started_at.present? || completed_at.present? ||
        failure_message.present?
      next false unless changed

      update!(
        status: :pending,
        scanned_through: rewound_through,
        requested_from: nil,
        requested_to: nil,
        run_id: nil,
        started_at: nil,
        completed_at: nil,
        failure_message: nil
      )
      true
    end
  end

  def fail!(candidate_run_id, error:)
    with_lock do
      return false unless current_run?(candidate_run_id)

      update!(
        status: :failed,
        run_id: nil,
        completed_at: Time.current,
        failure_message: error.message.to_s.truncate(500)
      )
      true
    end
  end

  private

  def requested_range_is_complete_and_chronological
    if requested_from.present? != requested_to.present?
      errors.add(:base, "requested range must include both boundaries")
    elsif requested_from.present? && requested_from > requested_to
      errors.add(:base, "requested range must be chronological")
    end
  end

  def validate_requested_range!(from:, to:)
    return if from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current

    raise ArgumentError, "scan range must use past dates in chronological order"
  end
end
