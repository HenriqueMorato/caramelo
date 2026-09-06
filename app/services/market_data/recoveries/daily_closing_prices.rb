module MarketData
  module Recoveries
    class DailyClosingPrices
      def self.call(target:, range:, batch_scope:, batch_run_id:, owner:, lease_token: nil)
        from, to = normalized_range(range)
        target_batch = RefreshStatus::Tracker.enqueue(scope: target.scope, total_count: 1)
        job = RecoverDailyClosingPricesJob.perform_later(
          instrument_id: target.record_id,
          from:,
          to:,
          target_scope: target.scope,
          target_run_id: target_batch.run_id,
          batch_scope:,
          batch_run_id:, lease_token:, lease_target: target.to_h
        )
        raise ActiveJob::EnqueueError, "daily closing-price recovery could not be enqueued" unless job

        job
      end

      def self.normalized_range(range)
        return [ TradingCalendar.previous_business_day, TradingCalendar.previous_business_day ] unless range
        return [ range.begin, range.end ] if range.is_a?(Range) && range.begin.is_a?(Date) && range.end.is_a?(Date)

        raise ArgumentError, "historical recovery range must use dates"
      end

      private_class_method :normalized_range
    end
  end
end
