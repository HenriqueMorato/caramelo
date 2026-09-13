module MarketData
  class HealthReport
    class DailyClosingPrices
      def initialize(owner:, instruments:, today:)
        @owner = owner
        @instruments = instruments
        @today = today
      end

      def entries
        instruments.map { |instrument| entry_for(instrument) }
      end

      def dates_for(instrument)
        first_trade_date = owner.trades.where(instrument:).order(:traded_on, :id).pick(:traded_on)
        return [] unless first_trade_date

        TradingCalendar.weekdays_between(first_trade_date, historical_end_date)
      end

      private

      attr_reader :owner, :instruments, :today

      def entry_for(instrument)
        required_dates = dates_for(instrument)
        observations = observations_for(instrument, required_dates)
        coverage = HealthReport::CoverageCalculator.for(required_dates:, observations:, carry_forward: true)
        present = coverage.complete?
        HealthReport::Entry.new(
          code: present ? :daily_close : :missing_daily_close,
          target: Target.new(
            kind: :daily_closing_prices, record_id: instrument.id,
            provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier
          ), subject: instrument,
          status: present ? :healthy : coverage.partial? ? :partial : :missing,
          severity: present ? nil : :warning, label: "#{instrument.ticker} · #{instrument.name}",
          description: description(instrument, coverage), observed_on: nil, fetched_at: nil,
          covered_range: coverage.covered_range, missing_range: coverage.missing_range,
          actions: present ? [] : [ :retry ]
        )
      end

      def observations_for(instrument, required_dates)
        return [] if required_dates.empty?

        instrument.daily_closing_prices.where(
          trading_date: (HistoricalObservationWindow.for(required_dates.min).begin..today)
        ).to_a
      end

      def historical_end_date
        @historical_end_date ||= if TradingCalendar.weekend?(today)
          TradingCalendar.previous_business_day(today + 1.day)
        else
          TradingCalendar.previous_business_day(today)
        end
      end

      def description(instrument, coverage)
        return "#{instrument.ticker} has historical closing prices." if coverage.complete?

        "#{instrument.ticker} is missing historical closing prices for #{format_ranges(coverage.missing_ranges)}."
      end

      def format_ranges(ranges)
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
      end
    end
  end
end
