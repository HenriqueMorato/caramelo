module ReportingCurrency
  class Preparation
    HISTORY_BATCH_SIZE = 60

    def initialize(user:, currency:, exchange_rates: ExchangeRate::Service.default,
      history: HistoricalExchangeRate::Importer.default, throttle: MarketData::YahooFinance::RequestThrottle.new,
      run_id: SecureRandom.uuid)
      @user = user
      @currency = CurrencyCode.normalize(currency)
      @exchange_rates = exchange_rates
      @history = history
      @throttle = throttle
      @run_id = run_id
    end

    def call
      scope = "reporting_currency:#{user.id}:#{currency}"
      starts = currency_starts
      if starts.empty?
        complete_without_work(scope)
        return
      end

      pairs = starts.except(currency)
      instruments = instrument_starts
      failures = []
      RefreshStatus::Tracker.perform(scope:, run_id:, total_count: pairs.size + instruments.size + 1) do |refresh|
        prepare_run_fence
        pairs.sort_by { |base_currency, _| base_currency }.each do |base_currency, first_trade|
          perform_step(refresh, failures, base_currency:) do
            prepare_pair(base_currency, first_trade)
          end
        end
        perform_step(refresh, failures, target: "portfolio") do
          enqueue_portfolio_rebuild(starts.values.min)
        end
        instruments.each do |instrument, first_trade|
          perform_step(refresh, failures, instrument_id: instrument.id) do
            enqueue_instrument_rebuild(instrument, first_trade)
          end
        end
        raise failures.first if failures.any?
      end
    end

    private

    attr_reader :user, :currency, :exchange_rates, :history, :throttle, :run_id, :run_fence, :run_generation

    def prepare_run_fence
      @run_fence = MarketData::PublicationFence.new(
        target: MarketData::Target.new(kind: :reporting_currency_preparation,
          record_id: user.id, quote_currency: currency)
      )
      @run_generation = run_fence.advance { |generation| generation }
    end

    def fenced_side_effect
      run_fence.publish(run_generation) { yield } == :published
    end

    def complete_without_work(scope)
      state = RefreshStatus::State.read(scope)
      return unless state&.run_id == run_id

      RefreshStatus::Tracker.perform(scope:, run_id:, total_count: 0) { }
    end

    def perform_step(refresh, failures, **context)
      return unless RefreshStatus::Tracker.current?(refresh)

      yield
    rescue StandardError => error
      failures << error if failures.empty?
      RefreshStatus::Tracker.record_failure(refresh, error)
      Rails.error.report(
        error, handled: true, context: { user_id: user.id, reporting_currency: currency, **context }
      )
    ensure
      RefreshStatus::Tracker.advance(refresh)
    end

    def currency_starts
      trades = user.trades.where(traded_on: ..Date.current)
      native_starts = trades.group(:currency).minimum(:traded_on)
      settlement_starts = trades.where.not(settlement_currency: nil)
        .group(:settlement_currency).minimum(:traded_on)
      trade_starts = native_starts.merge(settlement_starts) { |_currency, native_date, settlement_date|
        [ native_date, settlement_date ].min
      }
      trade_starts = trade_starts.merge(corporate_action_currency_starts) { |_currency, trade_date, action_date|
        [ trade_date, action_date ].min
      }
      trade_starts.merge(benchmark_currency_starts) { |_currency, trade_date, benchmark_date|
        [ trade_date, benchmark_date ].min
      }
    end

    def enqueue_portfolio_rebuild(first_trade)
      result = nil
      return unless fenced_side_effect do
        result = Performance::SeriesRefresh.enqueue(
          user:, from: first_trade, to: Date.current, reporting_currency: currency
        )
      end

      raise ActiveJob::EnqueueError, "performance rebuild could not be enqueued" if result == :failed
    end

    def enqueue_instrument_rebuild(instrument, first_trade)
      result = nil
      return unless fenced_side_effect do
        result = Performance::SeriesRefresh.enqueue(
          user:, instrument:, from: first_trade, to: Date.current, reporting_currency: currency
        )
      end

      raise ActiveJob::EnqueueError, "instrument performance rebuild could not be enqueued" if result == :failed
    end

    def instrument_starts
      starts = user.trades.where(traded_on: ..Date.current).group(:instrument_id).minimum(:traded_on)
      starts.merge!(corporate_action_instrument_starts) { |_instrument_id, trade_date, action_date|
        [ trade_date, action_date ].min
      }
      Instrument.where(id: starts.keys).index_with { |instrument| starts.fetch(instrument.id) }
    end

    def corporate_action_currency_starts
      effective_corporate_actions.group_by { |action| action.currency || action.instrument.currency }.transform_values do |actions|
        actions.map(&:performance_on).min
      end
    end

    def benchmark_currency_starts
      first_activity = [
        user.trades.where(traded_on: ..Date.current).minimum(:traded_on),
        effective_corporate_actions.map(&:performance_on).min
      ].compact.min
      return {} unless first_activity

      benchmarks = MarketBenchmark.where(kind: MarketBenchmark::PERFORMANCE_KINDS).where.not(currency:).to_a
      benchmarks.group_by(&:currency).transform_values do |currency_benchmarks|
        currency_benchmarks.map do |benchmark|
          source_start = benchmark_importer.available_from_for(benchmark:)
          [ first_activity, source_start ].compact.max
        end.min
      end
    end

    def benchmark_importer
      @benchmark_importer ||= MarketBenchmark::Importer.default
    end

    def corporate_action_instrument_starts
      effective_corporate_actions.group_by(&:instrument_id).transform_values do |actions|
        actions.map(&:performance_on).min
      end
    end

    def effective_corporate_actions
      @effective_corporate_actions ||= user.corporate_actions.effective_on_or_before(Date.current)
        .includes(:instrument).to_a
    end

    def prepare_pair(base_currency, first_trade)
      if exchange_rates.read(base_currency:, quote_currency: currency).refresh_needed?
        return unless fenced_side_effect do
          throttle.wait!
          exchange_rates.refresh(base_currency:, quote_currency: currency)
        end
      end
      # Include the existing valuation lookback for a first trade on a holiday.
      from = MarketData::HistoricalObservationWindow.for(first_trade).begin
      fence, generation = historical_context(base_currency:)
      missing_ranges(base_currency, from:).each do |range|
        return unless fenced_side_effect do
          throttle.wait!
          history.call(base_currency:, quote_currency: currency, from: range.begin, to: range.end,
            enqueue_performance_rebuild: false, fence:, generation:)
        end
      end
    end

    def historical_context(base_currency:)
      @historical_contexts ||= {}
      @historical_contexts[base_currency] ||= begin
        fence = historical_fence(base_currency:)
        [ fence, fence.capture ]
      end
    end

    def historical_fence(base_currency:)
      @historical_fences ||= {}
      @historical_fences[base_currency] ||= MarketData::PublicationFence.new(
        target: MarketData::Target.new(kind: :historical_exchange_rates,
          base_currency:, quote_currency: currency,
          provider: HistoricalExchangeRate::Providers::YahooFinance::IDENTIFIER)
      )
    end

    def missing_ranges(base_currency, from:)
      today = Date.current
      direct = HistoricalExchangeRate.where(base_currency:, quote_currency: currency)
      inverse = HistoricalExchangeRate.where(base_currency: currency, quote_currency: base_currency)
      existing_dates = direct.or(inverse)
        .where(provider: HistoricalExchangeRate::Providers::YahooFinance::IDENTIFIER, rate_date: from..today)
        .pluck(:rate_date).to_set

      TradingCalendar.weekdays_between(from, today)
        .chunk { |date| existing_dates.include?(date) }
        .flat_map do |present, dates|
          present ? [] : dates.each_slice(HISTORY_BATCH_SIZE).map { |batch| batch.first..batch.last }
        end
    end
  end
end
