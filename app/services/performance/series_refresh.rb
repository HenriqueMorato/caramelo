module Performance
  class SeriesRefresh
    CACHE_PREFIX = "caramelo:performance_series_refresh"
    STATE_TTL = 1.day
    LEASE_TTL = 30.minutes
    FAILURE_COOLDOWN = 30.seconds

    class AlreadyRunning < StandardError; end
    class LeaseLost < StandardError; end

    # Disposable UI state for a durable portfolio or instrument request.
    class State
      attr_reader :status, :from, :to, :updated_at, :error_message, :phase

      def initialize(status:, from:, to:, updated_at:, error_message: nil, phase: nil)
        @status = status
        @from = from
        @to = to
        @updated_at = updated_at
        @error_message = error_message
        @phase = phase
        freeze
      end

      def active?
        %w[queued running].include?(status)
      end

      def failed?
        status == "failed"
      end

      def interrupted?
        active? && (!updated_at || updated_at <= LEASE_TTL.ago)
      end
    end

    def self.enqueue(user:, from:, to:, instrument: nil, reporting_currency: user.reporting_currency,
      refetch_dependencies: false, refetch_full_range: false, force: false, job_class: nil)
      new(user:, instrument:, from:, to:, reporting_currency:, refetch_dependencies:, refetch_full_range:,
        force:, job_class:).enqueue
    end

    def self.rebuild_now(user:, from:, to:, instrument: nil, reporting_currency: user.reporting_currency,
      refetch_dependencies: false, refetch_full_range: false, job_class: nil)
      new(user:, instrument:, from:, to:, reporting_currency:, refetch_dependencies:, refetch_full_range:,
        force: false, job_class:).rebuild_now
    end

    def self.read(user:, instrument: nil, reporting_currency: user.reporting_currency)
      payload = Rails.cache.read(state_key(user:, instrument:, reporting_currency:))
      return unless payload.is_a?(Hash)

      values = payload.symbolize_keys
      State.new(
        status: values.fetch(:status),
        from: Date.iso8601(values.fetch(:from)),
        to: Date.iso8601(values.fetch(:to)),
        updated_at: Time.iso8601(values.fetch(:updated_at)),
        error_message: values[:error_message], phase: values[:phase]
      )
    rescue ArgumentError, KeyError, TypeError
      nil
    end

    def self.running(user:, from:, to:, token:, instrument: nil, reporting_currency: user.reporting_currency,
      phase: nil)
      write(user:, instrument:, from:, to:, token:, reporting_currency:, status: "running", phase:,
        renew_lease: true)
    end

    def self.heartbeat!(user:, from:, to:, token:, instrument: nil, reporting_currency: user.reporting_currency,
      phase: nil)
      state = write(
        user:, instrument:, from:, to:, token:, reporting_currency:, status: "running", phase:,
        renew_lease: true
      )
      return state if state

      raise LeaseLost, "performance refresh lease expired before the build completed"
    end

    def self.queued(user:, from:, to:, token:, instrument: nil, reporting_currency: user.reporting_currency)
      write(user:, instrument:, from:, to:, token:, reporting_currency:, status: "queued", phase: nil)
    end

    def self.succeeded(user:, from:, to:, token:, instrument: nil, reporting_currency: user.reporting_currency)
      write(user:, instrument:, from:, to:, token:, reporting_currency:, status: "succeeded", phase: nil)
    end

    def self.failed(user:, from:, to:, error:, token:, instrument: nil, reporting_currency: user.reporting_currency)
      write(
        user:, instrument:, from:, to:, token:, reporting_currency:, status: "failed",
        error_message: error.message.truncate(500), phase: nil
      )
    end

    def self.release(user:, token:, instrument: nil, reporting_currency: user.reporting_currency)
      with_current_lease(user:, instrument:, token:, reporting_currency:) do
        Rails.cache.delete(lease_key(user:, instrument:, reporting_currency:))
      end
    end

    def self.acquire(user:, instrument: nil, reporting_currency: user.reporting_currency)
      materialization_for(user:, instrument:, reporting_currency:).with_lock do
        token = SecureRandom.uuid
        acquired = Rails.cache.write(
          lease_key(user:, instrument:, reporting_currency:), token,
          expires_in: LEASE_TTL, unless_exist: true
        )
        token if acquired
      end
    end

    def initialize(user:, instrument:, from:, to:, reporting_currency:, refetch_dependencies:, refetch_full_range:,
      force:, job_class:, materialization: nil)
      @user = user
      @instrument = instrument
      @from = from
      @to = to
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
      @refetch_dependencies = refetch_dependencies
      @refetch_full_range = refetch_full_range
      @force = force
      @job_class = job_class || default_job_class
      @materialization = materialization || self.class.send(
        :materialization_for, user:, instrument:, reporting_currency: @reporting_currency
      )
    end

    def enqueue
      materialization.request!(from:, to:)
      return :failed if !force && recent_failure?(self.class.read(user:, instrument:, reporting_currency:))
      token = acquire_lease
      return existing_refresh_status unless token

      enqueue_job(token)
    end

    def rebuild_now
      materialization.request!(from:, to:, source_changed: true)
      token = acquire_lease
      raise AlreadyRunning, "performance observations are already rebuilding for this target" unless token

      lease_owned = true
      mark_queued(token)
      lease_owned = false
      job_class.perform_now(**job_arguments(token))
    rescue StandardError
      self.class.release(user:, instrument:, token:, reporting_currency:) if lease_owned
      raise
    end

    private

    attr_reader :user, :instrument, :from, :to, :reporting_currency, :job_class, :materialization,
      :refetch_dependencies, :refetch_full_range, :force

    def default_job_class
      instrument ? BuildInstrumentPerformanceObservationsJob : BuildPortfolioPerformanceObservationsJob
    end

    def enqueue_job(token)
      mark_queued(token)
      job = job_class.perform_later(**job_arguments(token))
      return :queued if job.successfully_enqueued?

      raise ActiveJob::EnqueueError, "performance observation build could not be enqueued"
    rescue StandardError => error
      report_enqueue_failure(error, token:)
    end

    def mark_queued(token)
      requested_range = materialization.requested_range
      self.class.queued(
        user:, instrument:, from: requested_range.begin, to: requested_range.end, token:, reporting_currency:
      )
    end

    def report_enqueue_failure(error, token:)
      requested_range = materialization.requested_range
      refresh_class = self.class
      refresh_class.failed(
        user:, instrument:, from: requested_range.begin, to: requested_range.end,
        reporting_currency:, token:, error:
      )
      refresh_class.release(user:, instrument:, token:, reporting_currency:)
      Rails.error.report(
        error, handled: true, context: { user_id: user.id, instrument_id: instrument&.id, from:, to: }
      )
      :failed
    end

    def acquire_lease
      self.class.acquire(user:, instrument:, reporting_currency:)
    end

    def existing_refresh_status
      state = self.class.read(user:, instrument:, reporting_currency:)
      state&.status == "queued" ? :queued : :active
    end

    def recent_failure?(state)
      state&.failed? && state.updated_at > FAILURE_COOLDOWN.ago
    end

    def job_arguments(token)
      arguments = { user_id: user.id, reporting_currency:, lease_token: token }
      arguments[:instrument_id] = instrument.id if instrument
      arguments[:refetch_dependencies] = true if refetch_dependencies
      arguments[:refetch_full_range] = true if refetch_full_range
      arguments
    end

    class << self
      private

      def write(user:, instrument:, from:, to:, token:, reporting_currency:, status:, error_message: nil,
        phase: nil, renew_lease: false)
        written = false
        with_current_lease(user:, instrument:, token:, reporting_currency:) do
          cache = Rails.cache
          cache.write(
            lease_key(user:, instrument:, reporting_currency:), token, expires_in: LEASE_TTL
          ) if renew_lease
          cache.write(
            state_key(user:, instrument:, reporting_currency:),
            state_payload(from:, to:, status:, error_message:, phase:),
            expires_in: STATE_TTL
          )
          written = true
        end
        read(user:, instrument:, reporting_currency:) if written
      end

      def state_payload(from:, to:, status:, error_message:, phase:)
        {
          status:,
          from: from.iso8601,
          to: to.iso8601,
          updated_at: Time.current.iso8601(6),
          error_message:,
          phase:
        }
      end

      def with_current_lease(user:, instrument:, token:, reporting_currency:)
        materialization_for(user:, instrument:, reporting_currency:).with_lock do
          yield if Rails.cache.read(lease_key(user:, instrument:, reporting_currency:)) == token
        end
      end

      def state_key(user:, instrument:, reporting_currency:)
        "#{CACHE_PREFIX}:#{target_key(user:, instrument:, reporting_currency:)}:state"
      end

      def lease_key(user:, instrument:, reporting_currency:)
        "#{CACHE_PREFIX}:#{target_key(user:, instrument:, reporting_currency:)}:lease"
      end

      def target_key(user:, instrument:, reporting_currency:)
        user_id = user.id
        return "#{user_id}:#{reporting_currency}" unless instrument

        "#{user_id}:instrument:#{instrument.id}:#{reporting_currency}"
      end

      def materialization_for(user:, instrument:, reporting_currency:)
        if instrument
          InstrumentPerformanceMaterialization.for(user:, instrument:, reporting_currency:)
        else
          PortfolioPerformanceMaterialization.for(user:, reporting_currency:)
        end
      end
    end
  end
end
