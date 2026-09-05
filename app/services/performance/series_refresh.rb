module Performance
  class SeriesRefresh
    CACHE_PREFIX = "localfolio:performance_series_refresh"
    STATE_TTL = 1.day
    LEASE_TTL = 30.minutes
    FAILURE_COOLDOWN = 30.seconds

    class AlreadyRunning < StandardError; end

    # Disposable UI state for the durable requested range held by
    # PortfolioPerformanceMaterialization.
    class State
      attr_reader :status, :from, :to, :updated_at, :error_message

      def initialize(status:, from:, to:, updated_at:, error_message: nil)
        @status = status
        @from = from
        @to = to
        @updated_at = updated_at
        @error_message = error_message
        freeze
      end

      def active?
        %w[queued running].include?(status)
      end

      def failed?
        status == "failed"
      end
    end

    def self.enqueue(user:, from:, to:, reporting_currency: user.reporting_currency,
      job_class: BuildPortfolioPerformanceObservationsJob)
      new(user:, from:, to:, reporting_currency:, job_class:).enqueue
    end

    def self.rebuild_now(user:, from:, to:, reporting_currency: user.reporting_currency,
      job_class: BuildPortfolioPerformanceObservationsJob)
      new(user:, from:, to:, reporting_currency:, job_class:).rebuild_now
    end

    def self.read(user:, reporting_currency: user.reporting_currency)
      payload = Rails.cache.read(state_key(user:, reporting_currency:))
      return unless payload.is_a?(Hash)

      values = payload.symbolize_keys
      State.new(
        status: values.fetch(:status),
        from: Date.iso8601(values.fetch(:from)),
        to: Date.iso8601(values.fetch(:to)),
        updated_at: Time.iso8601(values.fetch(:updated_at)),
        error_message: values[:error_message]
      )
    rescue ArgumentError, KeyError, TypeError
      nil
    end

    def self.running(user:, from:, to:, token:, reporting_currency: user.reporting_currency)
      write(user:, from:, to:, token:, reporting_currency:, status: "running")
    end

    def self.queued(user:, from:, to:, token:, reporting_currency: user.reporting_currency)
      write(user:, from:, to:, token:, reporting_currency:, status: "queued")
    end

    def self.succeeded(user:, from:, to:, token:, reporting_currency: user.reporting_currency)
      write(user:, from:, to:, token:, reporting_currency:, status: "succeeded")
    end

    def self.failed(user:, from:, to:, error:, token:, reporting_currency: user.reporting_currency)
      write(
        user:, from:, to:, token:, reporting_currency:, status: "failed",
        error_message: error.message.truncate(500)
      )
    end

    def self.release(user:, token:, reporting_currency: user.reporting_currency)
      with_current_lease(user:, token:, reporting_currency:) do
        Rails.cache.delete(lease_key(user:, reporting_currency:))
      end
    end

    def self.acquire(user:, reporting_currency: user.reporting_currency)
      PortfolioPerformanceMaterialization.for(user:, reporting_currency:).with_lock do
        token = SecureRandom.uuid
        acquired = Rails.cache.write(
          lease_key(user:, reporting_currency:), token,
          expires_in: LEASE_TTL, unless_exist: true
        )
        token if acquired
      end
    end

    def initialize(user:, from:, to:, reporting_currency:, job_class:,
      materialization: PortfolioPerformanceMaterialization.for(user:, reporting_currency:))
      @user = user
      @from = from
      @to = to
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
      @job_class = job_class
      @materialization = materialization
    end

    def enqueue
      materialization.request!(from:, to:)
      return :failed if recent_failure?(self.class.read(user:, reporting_currency:))
      token = acquire_lease
      return existing_refresh_status unless token

      enqueue_job(token)
    end

    def rebuild_now
      materialization.request!(from:, to:, source_changed: true)
      token = acquire_lease
      raise AlreadyRunning, "portfolio performance observations are already rebuilding" unless token

      lease_owned = true
      mark_queued(token)
      lease_owned = false
      job_class.perform_now(user_id: user.id, reporting_currency:, lease_token: token)
    rescue StandardError
      self.class.release(user:, token:, reporting_currency:) if lease_owned
      raise
    end

    private

    attr_reader :user, :from, :to, :reporting_currency, :job_class, :materialization

    def enqueue_job(token)
      mark_queued(token)
      job = job_class.perform_later(user_id: user.id, reporting_currency:, lease_token: token)
      return :queued if job.successfully_enqueued?

      raise ActiveJob::EnqueueError, "performance observation build could not be enqueued"
    rescue StandardError => error
      report_enqueue_failure(error, token:)
    end

    def mark_queued(token)
      requested_range = materialization.requested_range
      self.class.queued(user:, from: requested_range.begin, to: requested_range.end, token:, reporting_currency:)
    end

    def report_enqueue_failure(error, token:)
      requested_range = materialization.requested_range
      self.class.failed(
        user:, from: requested_range.begin, to: requested_range.end,
        reporting_currency:, token:, error:
      )
      self.class.release(user:, token:, reporting_currency:)
      Rails.error.report(error, handled: true, context: { user_id: user.id, from:, to: })
      :failed
    end

    def acquire_lease
      self.class.acquire(user:, reporting_currency:)
    end

    def existing_refresh_status
      state = self.class.read(user:, reporting_currency:)
      state&.status == "queued" ? :queued : :active
    end

    def recent_failure?(state)
      state&.failed? && state.updated_at > FAILURE_COOLDOWN.ago
    end

    class << self
      private

      def write(user:, from:, to:, token:, reporting_currency:, status:, error_message: nil)
        with_current_lease(user:, token:, reporting_currency:) do
          Rails.cache.write(
            state_key(user:, reporting_currency:),
            state_payload(from:, to:, status:, error_message:),
            expires_in: STATE_TTL
          )
        end
        read(user:, reporting_currency:)
      end

      def state_payload(from:, to:, status:, error_message:)
        {
          status:,
          from: from.iso8601,
          to: to.iso8601,
          updated_at: Time.current.iso8601(6),
          error_message:
        }
      end

      def with_current_lease(user:, token:, reporting_currency:)
        PortfolioPerformanceMaterialization.for(user:, reporting_currency:).with_lock do
          yield if Rails.cache.read(lease_key(user:, reporting_currency:)) == token
        end
      end

      def state_key(user:, reporting_currency:)
        "#{CACHE_PREFIX}:#{user.id}:#{reporting_currency}:state"
      end

      def lease_key(user:, reporting_currency:)
        "#{CACHE_PREFIX}:#{user.id}:#{reporting_currency}:lease"
      end
    end
  end
end
