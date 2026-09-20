module MarketData
  module Recoveries
    class PerformanceObservations
      def self.call(target:, range:, owner:, **)
        from, to = normalized_range(target:, range:, owner:)
        attributes = {
          user: owner,
          from:,
          to:,
          reporting_currency: target.quote_currency || owner.reporting_currency
        }
        attributes[:instrument] = Instrument.find(target.record_id) if target.kind == :instrument_performance
        result = Performance::SeriesRefresh.enqueue(**attributes)
        raise ActiveJob::EnqueueError, "performance recovery could not be enqueued" if result == :failed

        RefreshCurrentMarketPriceJob::COALESCED
      end

      def self.normalized_range(target:, range:, owner:)
        return [ range.begin, range.end ] if range

        trades = owner.trades
        actions = owner.corporate_actions.effective_on_or_before(Date.current)
        if target.kind == :instrument_performance
          trades = trades.where(instrument_id: target.record_id)
          actions = actions.where(instrument_id: target.record_id)
        end
        first_activity = [ trades.minimum(:traded_on), actions.minimum_performance_on ].compact.min
        [ first_activity || Date.current, Date.current ]
      end
      private_class_method :normalized_range
    end
  end
end
