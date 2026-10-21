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
        result = Performance::SeriesRefresh.enqueue(
          **attributes, refetch_dependencies: true, force: true
        )
        raise ActiveJob::EnqueueError, "performance recovery could not be enqueued" if result == :failed

        MarketData::Recovery::ASYNC
      end

      def self.normalized_range(target:, range:, owner:)
        if range
          from, to = range.begin, range.end
          validate_range!(from:, to:)
          return [ from, to ]
        end

        trades = owner.trades
        actions = owner.corporate_actions.effective_on_or_before(Date.current)
        if target.kind == :instrument_performance
          trades = trades.where(instrument_id: target.record_id)
          actions = actions.where(instrument_id: target.record_id)
        end
        first_activity = [ trades.minimum(:traded_on), actions.minimum_performance_on ].compact.min
        from = first_activity || Date.current
        validate_range!(from:, to: Date.current)
        [ from, Date.current ]
      end

      def self.validate_range!(from:, to:)
        return if (to - from).to_i <= Performance::HistoricalDependencyFetcher::MAX_RANGE_DAYS

        raise ArgumentError, "performance recovery range exceeds the maximum recovery span"
      end

      private_class_method :normalized_range, :validate_range!
    end
  end
end
