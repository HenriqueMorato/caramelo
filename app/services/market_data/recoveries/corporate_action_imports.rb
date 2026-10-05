module MarketData
  module Recoveries
    class CorporateActionImports
      def self.call(target:, owner:, **)
        instrument = Instrument.find(target.record_id)
        raise ActiveRecord::RecordNotFound unless owner.trades.exists?(instrument:)

        result = ::CorporateActionImports::Automation.call(
          user: owner, instrument:, source: target.provider || ::CorporateActionImports::Automation::SOURCE
        )
        raise ActiveJob::EnqueueError, "corporate action scan could not be enqueued" if result.failed?

        RefreshCurrentMarketPriceJob::COALESCED
      end
    end
  end
end
