class HistoricalDataBackfill < ApplicationRecord
  COALESCED = :coalesced

  belongs_to :instrument

  normalizes :currency, with: ->(currency) { currency.strip.upcase }

  validates :currency, presence: true, iso_currency: true
  validates :from_date, presence: true
  validates :generation, numericality: { only_integer: true, greater_than: 0 }
  validate :currency_matches_instrument

  def self.enqueue_for(instrument:, currency:, from_date:)
    request, created = coalesce(instrument:, currency:, from_date:)
    return COALESCED unless created

    job = BackfillHistoricalMarketDataJob.perform_later(request)
    return job if job

    request.destroy!
    nil
  rescue
    request&.destroy! if created
    raise
  end

  def self.pending_for?(owner: User.owner)
    where(instrument_id: owner.trades.select(:instrument_id)).exists?
  end

  def self.coalesce(instrument:, currency:, from_date:)
    currency = CurrencyCode.normalize(currency)
    transaction(requires_new: true) do
      request = find_or_initialize_by(instrument:, currency:)
      if request.new_record?
        request.from_date = from_date
        request.save!
        [ request, true ]
      elsif from_date < request.from_date
        request.update!(from_date:, generation: request.generation + 1)
        [ request, false ]
      else
        [ request, false ]
      end
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  private

  def currency_matches_instrument
    return if currency.blank? || instrument.blank? || currency == instrument.currency

    errors.add(:currency, :instrument_mismatch)
  end
end
