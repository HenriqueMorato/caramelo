class PortfolioPerformanceMaterialization < ApplicationRecord
  include PerformanceMaterializationRange

  # One owner's derived history in one reporting currency. `source_generation`
  # fences older calculations; the requested bounds coalesce unfinished work
  # and survive cache loss, failed enqueues, and worker restarts.
  belongs_to :user

  def self.for(user:, reporting_currency: user.reporting_currency)
    find_or_create_by!(user:, reporting_currency: CurrencyCode.normalize(reporting_currency))
  end
end
