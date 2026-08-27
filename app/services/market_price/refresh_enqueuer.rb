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
      job = job_class.perform_later(instrument, force: true)
      return job if job.successfully_enqueued?

      raise ActiveJob::EnqueueError, "current market price refresh could not be enqueued"
    rescue
      broadcaster.current(instrument:)
      raise
    end

    private

    attr_reader :service, :broadcaster, :job_class
  end
end
