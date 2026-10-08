module MarketData
  class HealthReport
    class HistoricalExchangeRates
      def initialize(owner:, context: nil)
        @owner = owner
        @context = context
      end

      def entries
        currencies = (
          trades.flat_map { |trade| [ trade.currency, trade.instrument.currency ] } +
          corporate_actions.map { |action| action.currency || action.instrument.currency } +
          benchmark_currencies
        ).uniq
        currencies.map { |currency| entry_for(currency) }
      end

      private

      attr_reader :owner, :context

      def entry_for(currency)
        required_dates = historical_rate_dates(currency)
        observations = observations_for(currency, required_dates)
        coverage = if currency == owner.reporting_currency
          CoverageCalculator.for(
            required_dates:, observations: required_dates.map { |date| HistoricalExchangeRate.new(rate_date: date) }
          )
        else
          CoverageCalculator.for(required_dates:, observations:, carry_forward: true)
        end
        present = coverage.complete?
        HealthReport::Entry.new(
          code: present ? :exchange_rate : :missing_exchange_rate,
          status: present ? :healthy : coverage.partial? ? :partial : :missing,
          severity: present ? nil : :warning, subject: currency, label: currency,
          description: description(currency:, coverage:),
          target: Target.new(kind: :historical_exchange_rates,
            base_currency: currency, quote_currency: owner.reporting_currency,
            provider: MarketData::YahooFinance::FX_CONFIGURATION.identifier),
          actions: present ? [] : [ :retry ], observed_on: nil, fetched_at: nil,
          covered_range: coverage.covered_range, missing_range: coverage.missing_range
        )
      end

      def observations_for(currency, required_dates)
        return [] if required_dates.empty?

        query_range = HistoricalObservationWindow.for(required_dates.min).begin..required_dates.max
        direct = HistoricalExchangeRate.where(
          base_currency: currency, quote_currency: owner.reporting_currency, rate_date: query_range
        )
        inverse = HistoricalExchangeRate.where(
          base_currency: owner.reporting_currency, quote_currency: currency, rate_date: query_range
        )
        direct.to_a + inverse.to_a
      end

      def historical_rate_dates(currency)
        settlement_dates = trades.select { |trade| trade.currency == currency }.map(&:traded_on)
        income_dates = corporate_actions.filter_map do |action|
          action.performance_on if (action.currency || action.instrument.currency) == currency
        end
        (settlement_dates + income_dates + valuation_dates(currency) + benchmark_dates(currency)).uniq
      end

      def benchmark_currencies
        MarketBenchmark.where(kind: %w[price total_return]).where.not(currency: owner.reporting_currency).distinct.pluck(:currency)
      end

      def benchmark_dates(currency)
        return [] if currency == owner.reporting_currency

        first_date = context&.first_performance_date || trades.map(&:traded_on).min
        return [] unless first_date

        benchmark_for_currency(currency).flat_map do |benchmark|
          end_date = benchmark_end_date(benchmark)
          start_date = [ first_date, benchmark_start_date(benchmark) ].compact.max
          next [] if end_date < start_date

          benchmark_importer.expected_dates_for(benchmark:, from: start_date, to: end_date)
        end
      end

      def benchmark_start_date(benchmark)
        return unless benchmark_importer.respond_to?(:available_from_for)

        benchmark_importer.available_from_for(benchmark:)
      end

      def benchmark_end_date(benchmark)
        benchmark_importer.available_through_for(benchmark:, on: context_today) || historical_end_date
      end

      def historical_end_date
        @historical_end_date ||= if TradingCalendar.weekend?(context_today)
          TradingCalendar.previous_business_day(context_today + 1.day)
        else
          TradingCalendar.previous_business_day(context_today)
        end
      end

      def benchmark_for_currency(currency)
        MarketBenchmark.where(kind: %w[price total_return], currency:)
      end

      def benchmark_importer
        @benchmark_importer ||= MarketBenchmark::Importer.default
      end

      def valuation_dates(currency)
        return [] if currency == owner.reporting_currency

        instruments = trades.filter_map { |trade| trade.instrument if trade.instrument.currency == currency }.uniq
        instruments.flat_map { |instrument| open_position_dates(instrument) }
      end

      def open_position_dates(instrument)
        instrument_trades = trades.select { |trade| trade.instrument == instrument }
        return [] if instrument_trades.empty?

        instrument_actions = corporate_actions.select do |action|
          action.instrument == instrument && action.quantity_action?
        end
        quantities = Position::Calculator.quantity_timeline(
          trades: instrument_trades,
          corporate_actions: instrument_actions,
          amount_for: ->(trade) { trade.total_amount },
          cash_in_lieu_amount_for: ->(action) { action.cash_in_lieu_amount&.to_d }
        )
        quantity = 0.to_r
        (instrument_trades.first.traded_on..context_today).filter_map do |date|
          quantity = quantities.fetch(date, quantity)
          date if quantity.positive?
        end
      rescue Position::InvalidLongOnlyData, Position::InvalidQuantityActionData
        open_trade_position_dates(instrument_trades)
      end

      def open_trade_position_dates(instrument_trades)
        events = instrument_trades.group_by(&:traded_on)
        quantity = 0.to_d
        (instrument_trades.first.traded_on..context_today).filter_map do |date|
          events.fetch(date, []).each { |trade| quantity += trade.buy? ? trade.quantity : -trade.quantity }
          date if quantity.positive?
        end
      end

      def trades
        @trades ||= context ? context.trades : owner.trades.includes(:instrument).order(:traded_on, :id).to_a
      end

      def corporate_actions
        @corporate_actions ||= if context
          context.corporate_actions
        else
          owner.corporate_actions.effective_on_or_before(context_today).includes(:instrument).to_a
        end
      end

      def context_today
        context&.today || Date.current
      end

      def description(currency:, coverage:)
        return "Historical #{currency}/#{owner.reporting_currency} rates are available." if coverage.complete?

        "Historical #{currency}/#{owner.reporting_currency} rates are missing for #{format_ranges(coverage.missing_ranges)}."
      end

      def format_ranges(ranges)
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
      end
    end
  end
end
