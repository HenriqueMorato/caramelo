module MarketData
  module Recoveries
    class HistoricalExchangeRates
      def self.call(target:, range:, batch_scope:, batch_run_id:, owner:)
        from, to = normalized_range(range)
        target_batch = RefreshStatus::Tracker.enqueue(scope: target.scope, total_count: 1)
        job = RecoverHistoricalExchangeRatesJob.perform_later(
          base_currency: target.base_currency,
          quote_currency: target.quote_currency,
          from:,
          to:,
          target_scope: target.scope,
          target_run_id: target_batch.run_id,
          batch_scope:,
          batch_run_id:
        )
        raise ActiveJob::EnqueueError, "historical exchange-rate recovery could not be enqueued" unless job

        job
      end

      def self.normalized_range(range)
        return [ TradingCalendar.previous_business_day, TradingCalendar.previous_business_day ] unless range
        return range if range.is_a?(Range) && range.begin.is_a?(Date) && range.end.is_a?(Date)

        raise ArgumentError, "historical recovery range must use dates"
      end

      private_class_method :normalized_range
    end
  end
end
