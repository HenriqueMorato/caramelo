module MarketPrice
  class RefreshEnqueuer
    def initialize(service: Service.default, broadcaster: nil, job_class: RefreshCurrentMarketPriceJob)
      @service = service
      @broadcaster = broadcaster || Broadcaster.new(service:)
      @job_class = job_class
    end

    def enqueue(instrument:)
      return unless service.supports?(instrument:)

      broadcaster.refreshing(instrument:)
      job = job_class.enqueue_for(instrument:, force: true)
      return job if job

      raise EnqueueFailure, "current market price refresh could not be enqueued"
    rescue
      broadcaster.current(instrument:)
      raise
    end

    def enqueue_if_needed(instrument:)
      return unless service.supports?(instrument:)

      lookup = service.read(instrument:)
      return unless lookup&.refresh_needed?

      job_class.enqueue_for(instrument:)
    end

    private

    attr_reader :service, :broadcaster, :job_class
  end
end
