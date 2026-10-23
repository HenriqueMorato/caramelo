module MarketData
  class ObservationImporter
    def call(from:, to:, enqueue_performance_rebuild: true, fence: nil, generation: nil)
      @superseded = false
      validate_request!(from:, to:)
      generation ||= fence&.capture
      @from = from
      @to = to
      @observations = fetch_observations
      validate_observations!
      counts = persist_with_fence(fence:, generation:)
      return result_for(counts:) if @superseded

      enqueue_performance_observations if enqueue_performance_rebuild && should_enqueue_performance_rebuild?

      result_for(counts:)
    end

    private

    attr_reader :from, :to, :observations, :performance_users

    def persist_with_fence(fence:, generation:)
      return persist_with_invalidation unless fence

      result = nil
      if fence.publish(generation) { result = persist_with_invalidation } == :superseded
        @superseded = true
        return superseded_counts
      end

      result
    end

    def superseded_counts
      { created: 0, updated: 0 }
    end

    def should_enqueue_performance_rebuild?
      true
    end
  end
end
