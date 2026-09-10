class InstrumentPerformanceMaterialization < ApplicationRecord
  include PerformanceMaterializationRange

  # One independently derived instrument history in one currency view.
  # Requested bounds and the source generation survive transient cache loss.
  belongs_to :user
  belongs_to :instrument

  validates :instrument, uniqueness: { scope: %i[user_id reporting_currency] }

  def self.for(user:, instrument:, reporting_currency: user.reporting_currency)
    find_or_create_by!(
      user:,
      instrument:,
      reporting_currency: CurrencyCode.normalize(reporting_currency)
    )
  end
end
