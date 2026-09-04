module MarketData
  module Recoveries
    class CurrentExchangeRate
      def self.call(target:, range:, batch_scope:, batch_run_id:, owner:)
        target_batch = RefreshStatus::Tracker.enqueue(scope: target.scope, total_count: 1)
        job = RecoverCurrentExchangeRateJob.perform_later(
          base_currency: target.base_currency,
          quote_currency: target.quote_currency,
          target_scope: target.scope,
          target_run_id: target_batch.run_id,
          batch_scope:,
          batch_run_id:
        )
        raise ActiveJob::EnqueueError, "current exchange-rate recovery could not be enqueued" unless job

        job
      end
    end
  end
end
