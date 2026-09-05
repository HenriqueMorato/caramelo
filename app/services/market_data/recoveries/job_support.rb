module MarketData
  module Recoveries
    module JobSupport
      private

      def run_target(target_scope:, target_run_id:, batch_scope:, batch_run_id:)
        completed = false
        RefreshStatus::Tracker.perform(
          scope: target_scope, total_count: 1, preserve_progress: true, run_id: target_run_id
        ) do |refresh|
          yield
          RefreshStatus::Tracker.advance(refresh)
          completed = true
        end
      rescue StandardError => error
        BatchProgress.fail(scope: batch_scope, run_id: batch_run_id, error:)
        Rails.error.report(error, handled: true, context: { target_scope: })
      ensure
        BatchProgress.advance(scope: batch_scope, run_id: batch_run_id) if completed
      end
    end
  end
end
