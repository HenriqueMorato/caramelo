module RefreshStatus
  class State
    CACHE_PREFIX = "caramelo:refresh_status:v1"
    ACTIVE_TIMEOUT = 10.minutes
    LOCK_EXPIRY = 30.seconds
    LOCK_RETRY_INTERVAL = 0.05.seconds
    EXPECTED_RUN_UNSET = Object.new.freeze
    NO_RUN = Object.new.freeze
    SCOPES_KEY = "#{CACHE_PREFIX}:scopes"
    DEFAULT_SCOPES = [
      RefreshStatus::MARKET_PRICE_SCOPE, "daily_closing_prices", "historical_exchange_rates", "market_benchmarks"
    ].freeze

    attr_reader :scope, :run_id, :status, :started_at, :finished_at, :updated_at,
      :error_class, :error_message, :processed_count, :total_count, :completed_items, :tracked_items

    def initialize(scope:, run_id: nil, status:, started_at:, finished_at:, error_class:, error_message:,
      processed_count:, total_count:, completed_items: nil, tracked_items: nil, updated_at: nil)
      @scope = scope
      @run_id = run_id
      @status = status
      @started_at = started_at
      @finished_at = finished_at
      @updated_at = updated_at
      @error_class = error_class
      @error_message = error_message
      @processed_count = processed_count
      @total_count = total_count
      @completed_items = completed_items&.map(&:to_s)&.uniq&.freeze
      @tracked_items = tracked_items&.map(&:to_s)&.uniq&.freeze
      freeze
    end

    def active?
      %w[queued running].include?(status)
    end

    def running?
      status == "running"
    end

    def queued?
      status == "queued"
    end

    def interrupted?
      active? && (!updated_at || updated_at <= ACTIVE_TIMEOUT.ago)
    end

    def failed?
      status == "failed"
    end

    def progress_label
      total_count && "#{processed_count}/#{total_count}"
    end

    def self.read(scope)
      payload = Rails.cache.read(key(scope))
      return unless payload

      values = payload.symbolize_keys
      new(**values.merge(
        started_at: parse_time(values[:started_at]),
        finished_at: parse_time(values[:finished_at]),
        updated_at: parse_time(values[:updated_at])
      ))
    end

    def self.scopes
      (DEFAULT_SCOPES + Array(Rails.cache.read(SCOPES_KEY))).uniq
    end

    def self.active
      scopes.filter_map do |scope|
        next if hidden_activity_scope?(scope)

        state = read(scope)
        state if state&.active? && state.updated_at && state.updated_at > ACTIVE_TIMEOUT.ago
      end
    end

    def self.prune!
      with_lock(SCOPES_KEY) do
        retained = scopes.select do |scope|
          state = read(scope)
          state && state.updated_at && state.updated_at > ACTIVE_TIMEOUT.ago
        end
        Rails.cache.write(SCOPES_KEY, retained)
        retained
      end
    end

    def self.latest_successful
      states_with_finish_time("succeeded").max_by(&:finished_at)
    end

    def self.latest_failed
      states_with_finish_time("failed").max_by(&:finished_at)
    end

    def self.write(scope:, run_id: nil, status:, started_at: nil, finished_at: nil, error_class: nil,
      error_message: nil, processed_count: 0, total_count: nil, completed_items: nil, tracked_items: nil,
      expected_run_id: EXPECTED_RUN_UNSET)
      with_lock(scope) do
        current = read(scope)
        if expected_run_id != EXPECTED_RUN_UNSET
          next if expected_run_id == NO_RUN ? current : current&.run_id != expected_run_id
        end

        write_unlocked(
          scope:, run_id:, status:, started_at: serialize_time(started_at), finished_at: serialize_time(finished_at),
          updated_at: serialize_time(Time.current), error_class:, error_message:, processed_count:, total_count:,
          completed_items:, tracked_items:
        )
      end
    end

    def self.advance(scope:, run_id:, item:)
      with_lock(scope) do
        current = read(scope)
        next unless current && current.run_id == run_id
        next current unless current.active?

        item = item.to_s
        next current if current.tracked_items && !current.tracked_items.include?(item)

        completed_items = Array(current.completed_items)
        next current if completed_items.include?(item)

        processed_count = current.processed_count + 1
        completed = current.total_count && processed_count >= current.total_count && !current.failed?
        write_unlocked(
          scope: current.scope,
          run_id: current.run_id,
          status: completed ? "succeeded" : current.status,
          started_at: serialize_time(current.started_at),
          finished_at: serialize_time(completed ? Time.current : current.finished_at),
          updated_at: serialize_time(Time.current),
          error_class: current.error_class,
          error_message: current.error_message,
          processed_count:,
          total_count: current.total_count,
          completed_items: completed_items | [ item ],
          tracked_items: current.tracked_items
        )
      end
    end

    def self.reconcile(scope:, run_id:, total_count:, tracked_items:)
      with_lock(scope) do
        current = read(scope)
        next unless current&.active? && current.run_id == run_id

        tracked_items = tracked_items&.map(&:to_s)&.uniq || current.tracked_items
        completed_items = if tracked_items
          Array(current.completed_items).intersection(tracked_items)
        else
          current.completed_items
        end
        write_unlocked(
          scope: current.scope,
          run_id: current.run_id,
          status: "running",
          started_at: serialize_time(current.started_at || Time.current),
          finished_at: serialize_time(current.finished_at),
          updated_at: serialize_time(Time.current),
          error_class: current.error_class,
          error_message: current.error_message,
          processed_count: tracked_items ? completed_items.length : current.processed_count,
          total_count: total_count || current.total_count,
          completed_items:,
          tracked_items:
        )
      end
    end

    def self.key(scope)
      "#{CACHE_PREFIX}:#{scope}"
    end

    def self.serialize_time(value)
      value&.iso8601(6)
    end

    def self.parse_time(value)
      value && Time.iso8601(value)
    end

    def self.register(scope)
      with_lock(SCOPES_KEY) do
        cache = Rails.cache
        scopes = Array(cache.read(SCOPES_KEY)) | [ scope ]
        cache.write(SCOPES_KEY, scopes)
      end
    end

    def self.with_lock(scope)
      token = SecureRandom.uuid
      acquire_lock(scope, token)
      yield
    ensure
      release_lock(scope, token)
    end

    def self.acquire_lock(scope, token)
      until Rails.cache.write(lock_key(scope), token, expires_in: LOCK_EXPIRY, unless_exist: true)
        sleep LOCK_RETRY_INTERVAL
      end
    end

    def self.release_lock(scope, token)
      lock = lock_key(scope)
      cache = Rails.cache
      cache.delete(lock) if token && cache.read(lock) == token
    end

    def self.lock_key(scope)
      "#{key(scope)}:lock"
    end

    def self.write_unlocked(scope:, run_id:, status:, started_at:, finished_at:, updated_at:, error_class:,
      error_message:, processed_count:, total_count:, completed_items:, tracked_items:)
      register(scope)
      Rails.cache.write(key(scope), {
        scope:, run_id:, status:, started_at:, finished_at:, updated_at:, error_class:, error_message:,
        processed_count:, total_count:, completed_items:, tracked_items:
      })
      state = read(scope)
      register(scope)
      state
    end

    def self.states_with_finish_time(status)
      scopes.filter_map do |scope|
        next if hidden_activity_scope?(scope)

        state = read(scope)
        state if state&.status == status && state.finished_at
      end
    end

    # Per-instrument leases support refresh bookkeeping but should not keep the global toast open.
    def self.hidden_activity_scope?(scope)
      scope.match?(/\Acurrent_market_price:\d+\z/) ||
        scope.start_with?("market_data_recovery:") ||
        scope.start_with?(CorporateActionImports::ScanStatus::SCOPE_PREFIX)
    end

    private_class_method :register, :serialize_time, :parse_time, :key, :states_with_finish_time,
      :hidden_activity_scope?, :with_lock, :acquire_lock, :release_lock, :lock_key, :write_unlocked
  end
end
