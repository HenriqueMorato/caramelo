module ReportingCurrency
  class Preparation
    HISTORY_BATCH_SIZE = 60

    def initialize(user:, currency:, exchange_rates: ExchangeRate::Service.default,
      history: HistoricalExchangeRate::Importer.default, throttle: MarketData::YahooFinance::RequestThrottle.new)
      @user = user
      @currency = CurrencyCode.normalize(currency)
      @exchange_rates = exchange_rates
      @history = history
      @throttle = throttle
    end

    def call
      starts = currency_starts
      return if starts.empty?

      pairs = starts.except(currency)
      instruments = instrument_starts
      scope = "reporting_currency:#{user.id}:#{currency}"
      RefreshStatus::Tracker.perform(scope:, total_count: pairs.size + instruments.size + 1) do |refresh|
        pairs.each do |base_currency, first_trade|
          prepare_pair(base_currency, first_trade)
          RefreshStatus::Tracker.advance(refresh)
        end
        enqueue_portfolio_rebuild(starts.values.min)
        RefreshStatus::Tracker.advance(refresh)
        instruments.each do |instrument, first_trade|
          enqueue_instrument_rebuild(instrument, first_trade)
          RefreshStatus::Tracker.advance(refresh)
        end
      end
    end

    private

    attr_reader :user, :currency, :exchange_rates, :history, :throttle

    def currency_starts
      trades = user.trades.where(traded_on: ..Date.current)
      native_starts = trades.group(:currency).minimum(:traded_on)
      settlement_starts = trades.where.not(settlement_currency: nil)
        .group(:settlement_currency).minimum(:traded_on)
      trade_starts = native_starts.merge(settlement_starts) { |_currency, native_date, settlement_date|
        [ native_date, settlement_date ].min
      }
      trade_starts.merge(corporate_action_currency_starts) { |_currency, trade_date, action_date|
        [ trade_date, action_date ].min
      }
    end

    def enqueue_portfolio_rebuild(first_trade)
      result = Performance::SeriesRefresh.enqueue(
        user:, from: first_trade, to: Date.current, reporting_currency: currency
      )
      raise ActiveJob::EnqueueError, "performance rebuild could not be enqueued" if result == :failed
    end

    def enqueue_instrument_rebuild(instrument, first_trade)
      result = Performance::SeriesRefresh.enqueue(
        user:, instrument:, from: first_trade, to: Date.current, reporting_currency: currency
      )
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
        throttle.wait!
        exchange_rates.refresh(base_currency:, quote_currency: currency)
      end
      # Include the existing valuation lookback for a first trade on a holiday.
      from = MarketData::HistoricalObservationWindow.for(first_trade).begin
      missing_ranges(base_currency, from:).each do |range|
        throttle.wait!
        history.call(base_currency:, quote_currency: currency, from: range.begin, to: range.end,
          enqueue_performance_rebuild: false)
      end
    end

    def missing_ranges(base_currency, from:)
      direct = HistoricalExchangeRate.where(base_currency:, quote_currency: currency)
      inverse = HistoricalExchangeRate.where(base_currency: currency, quote_currency: base_currency)
      existing_dates = direct.or(inverse)
        .where(provider: HistoricalExchangeRate::Providers::YahooFinance::IDENTIFIER, rate_date: from..Date.current)
        .pluck(:rate_date).to_set

      TradingCalendar.weekdays_between(from, Date.current)
        .chunk { |date| existing_dates.include?(date) }
        .flat_map do |present, dates|
          present ? [] : dates.each_slice(HISTORY_BATCH_SIZE).map { |batch| batch.first..batch.last }
        end
    end
  end
end
