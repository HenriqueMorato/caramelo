module MarketData
  module Recoveries
    module BatchProgress
      module_function

      def advance(scope:, run_id:)
        state = RefreshStatus::State.read(scope)
        return unless state&.active? && state.run_id == run_id

        RefreshStatus::Tracker.advance(state)
      end

      def fail(scope:, run_id:, error:)
        state = RefreshStatus::State.read(scope)
        return unless state&.active? && state.run_id == run_id

        RefreshStatus::Tracker.record_failure(state, error)
      end
    end
  end
end
