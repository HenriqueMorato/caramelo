module RefreshStatus
  class State
    CACHE_PREFIX = "localfolio:refresh_status:v1"
    ACTIVE_TIMEOUT = 10.minutes
    SCOPES_KEY = "#{CACHE_PREFIX}:scopes"
    DEFAULT_SCOPES = [
      RefreshStatus::MARKET_PRICE_SCOPE, "daily_closing_prices", "historical_exchange_rates", "market_benchmarks"
    ].freeze

    attr_reader :scope, :run_id, :status, :started_at, :finished_at, :updated_at,
      :error_class, :error_message, :processed_count, :total_count

    def initialize(scope:, run_id: nil, status:, started_at:, finished_at:, error_class:, error_message:,
      processed_count:, total_count:, updated_at: nil)
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
        next if instrument_scope?(scope)

        state = read(scope)
        state if state&.active? && state.updated_at && state.updated_at > ACTIVE_TIMEOUT.ago
      end
    end

    def self.prune!
      retained = scopes.select do |scope|
        state = read(scope)
        state && (!state.finished_at || state.updated_at > ACTIVE_TIMEOUT.ago)
      end
      Rails.cache.write(SCOPES_KEY, retained)
      retained
    end

    def self.latest_successful
      states_with_finish_time("succeeded").max_by(&:finished_at)
    end

    def self.latest_failed
      states_with_finish_time("failed").max_by(&:finished_at)
    end

    def self.write(scope:, run_id: nil, status:, started_at: nil, finished_at: nil, error_class: nil,
      error_message: nil,
      processed_count: 0, total_count: nil)
      register(scope)
      Rails.cache.write(key(scope), {
        scope:, run_id:, status:, started_at: serialize_time(started_at), finished_at: serialize_time(finished_at),
        updated_at: serialize_time(Time.current), error_class:, error_message:, processed_count:, total_count:
      })
      read(scope)
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
      scopes = Array(Rails.cache.read(SCOPES_KEY)) | [ scope ]
      Rails.cache.write(SCOPES_KEY, scopes)
    end

    def self.states_with_finish_time(status)
      scopes.filter_map { |scope| state = read(scope); state if state&.status == status && state.finished_at }
    end

    # Per-instrument leases support refresh bookkeeping but should not keep the global toast open.
    def self.instrument_scope?(scope)
      scope.match?(/\Acurrent_market_price:\d+\z/)
    end

    private_class_method :register, :serialize_time, :parse_time, :key, :states_with_finish_time, :instrument_scope?
  end
end
