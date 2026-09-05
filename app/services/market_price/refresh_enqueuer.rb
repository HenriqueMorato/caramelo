module MarketPrice
  class RefreshEnqueuer
    def initialize(service: Service.default, broadcaster: nil, job_class: RefreshCurrentMarketPriceJob)
      @service = service
      @broadcaster = broadcaster || Broadcaster.new(service:)
      @job_class = job_class
    end

    def enqueue(instrument:, batch_scope: nil, batch_run_id: nil)
      return unless service.supports?(instrument:)

      RefreshStatus::Tracker.enqueue(scope: job_class.refresh_scope(instrument)) unless batch_scope
      broadcaster.refreshing(instrument:)
      job = if batch_scope
        job_class.enqueue_for(instrument:, force: true, batch_scope:, batch_run_id:)
      else
        job_class.enqueue_for(instrument:, force: true)
      end
      return job if job

      raise EnqueueFailure, "current market price refresh could not be enqueued"
    rescue => error
      RefreshStatus::Tracker.fail(scope: job_class.refresh_scope(instrument), error:)
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
