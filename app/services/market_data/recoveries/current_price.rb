module MarketData
  module Recoveries
    class CurrentPrice
      def self.call(target:, range:, batch_scope:, batch_run_id:, owner:)
        instrument = Instrument.find(target.record_id)
        RefreshStatus::Tracker.enqueue(scope: target.scope, total_count: 1)
        result = MarketPrice::RefreshEnqueuer.new.enqueue(
          instrument:, batch_scope:, batch_run_id:
        )
        advance_target(target) if result.nil? || result == RefreshCurrentMarketPriceJob::COALESCED
        result
      end

      def self.advance_target(target)
        state = RefreshStatus::State.read(target.scope)
        RefreshStatus::Tracker.advance(state) if state&.active?
      end

      private_class_method :advance_target
    end
  end
end
