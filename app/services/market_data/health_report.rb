module MarketData
  class HealthReport
    Issue = Data.define(:code, :severity, :subject, :details) do
      def subject_label
        return "#{subject.ticker} · #{subject.name}" if subject.respond_to?(:ticker)
        return "#{subject.name} (#{subject.identifier})" if subject.respond_to?(:identifier)

        subject.to_s
      end
    end

    Entry = Data.define(
      :code, :target, :subject, :status, :severity, :label, :description,
      :observed_on, :fetched_at, :covered_range, :missing_range, :actions
    ) do
      def healthy? = status == :healthy
      def updating? = status == :updating
      def interrupted? = status == :interrupted
      def actionable? = actions.any?
      def quote_reset_needed? = target.kind == :current_price && target.record_id && !healthy? && !updating?
    end

    class Result
      attr_reader :checked_at, :issues, :entries

      def initialize(checked_at:, issues: nil, entries: nil)
        @checked_at = checked_at
        @entries = entries || issues.map { |issue| entry_for(issue) }
        @issues = issues || @entries.filter_map { |entry| issue_for(entry) }
      end

      def healthy? = issues.empty?
      def errors = issues.select { |issue| issue.severity == :error }
      def warnings = issues.select { |issue| issue.severity == :warning }

      def current_prices_need_refresh?
        entries.any? do |entry|
          entry.target.kind == :current_price && %i[missing stale].include?(entry.status)
        end
      end

      private

      def entry_for(issue)
        target = target_for(issue)
        status = issue.code.to_s.start_with?("stale_") ? :stale : :missing

        Entry.new(
          code: issue.code,
          target:,
          subject: issue.subject,
          status:,
          severity: issue.severity,
          label: issue.subject_label,
          description: issue.details,
          observed_on: nil,
          fetched_at: nil,
          covered_range: nil,
          missing_range: nil,
          actions: [ :retry ]
        )
      end

      def issue_for(entry)
        return if entry.healthy? || entry.severity.nil?

        Issue.new(
          code: entry.code,
          severity: entry.severity,
          subject: entry.subject,
          details: entry.description
        )
      end

      def target_for(issue)
        kind = case issue.code
        when :missing_current_price, :stale_current_price then :current_price
        when :missing_daily_close then :daily_closing_prices
        when :missing_exchange_rate then :historical_exchange_rates
        when :missing_benchmark_data then :benchmark_observations
        else :portfolio_performance
        end

        Target.new(kind:, record_id: issue.subject.respond_to?(:id) ? issue.subject.id : nil)
      end
    end

    def self.for(owner: User.owner, current_market_price_service: MarketPrice::Service.default,
      current_exchange_rate_service: ExchangeRate::Service.default, today: Date.current)
      new(owner:, current_market_price_service:, current_exchange_rate_service:, today:).call
    end

    def initialize(owner:, current_market_price_service:, current_exchange_rate_service: ExchangeRate::Service.default,
      today:)
      @owner = owner
      @current_market_price_service = current_market_price_service
      @current_exchange_rate_service = current_exchange_rate_service
      @today = today
    end

    def call
      entries = (instrument_entries + current_exchange_rate_entries + currency_entries + benchmark_entries + performance_entries)
        .sort_by { |entry| entry.severity == :error ? 0 : entry.severity == :warning ? 1 : 2 }
      Result.new(checked_at: Time.current, entries: entries)
    end

    private

    attr_reader :owner, :current_market_price_service, :current_exchange_rate_service, :today

    def instruments
      @instruments ||= owner.trades.includes(:instrument).map(&:instrument).uniq
    end

    def instrument_entries
      current = CurrentPrices.new(instruments:, service: current_market_price_service).entries
      current.zip(instruments.map { |instrument| daily_close_entry(instrument) }).flat_map(&:compact)
    end

    def daily_close_entry(instrument)
      required_dates = required_daily_close_dates(instrument)
      observations = if required_dates.empty?
        []
      else
        instrument.daily_closing_prices.where(
          trading_date: (HistoricalObservationWindow.for(required_dates.min).begin..today)
        ).to_a
      end
      coverage = CoverageCalculator.for(required_dates:, observations:, carry_forward: true)
      present = coverage.complete?
      entry_for(
        code: present ? :daily_close : :missing_daily_close,
        status: present ? :healthy : coverage.partial? ? :partial : :missing,
        severity: present ? nil : :warning,
        subject: instrument,
        description: daily_close_description(instrument, coverage),
        target: Target.new(kind: :daily_closing_prices, record_id: instrument.id),
        actions: present ? [] : [ :retry ], coverage: coverage
      )
    end

    def required_daily_close_dates(instrument)
      trade_dates = owner.trades.where(instrument:).order(:traded_on, :id).pluck(:traded_on)
      return [] if trade_dates.empty?

      TradingCalendar.weekdays_between(trade_dates.first, historical_end_date)
    end

    def daily_close_description(instrument, coverage)
      return "#{instrument.ticker} has historical closing prices." if coverage.complete?

      "#{instrument.ticker} is missing historical closing prices for #{format_ranges(coverage.missing_ranges)}."
    end

    def currency_entries
      currencies = owner.trades.distinct.pluck(:currency)
      reporting_currency = owner.reporting_currency
      currencies.map do |currency|
        required_dates = owner.trades.where(currency:).distinct.order(:traded_on).pluck(:traded_on)
        observations = HistoricalExchangeRate.where(
          base_currency: currency, quote_currency: reporting_currency, rate_date: required_dates
        ).to_a
        inverse_observations = HistoricalExchangeRate.where(
          base_currency: reporting_currency, quote_currency: currency, rate_date: required_dates
        ).to_a
        coverage = if currency == reporting_currency
          CoverageCalculator.for(
            required_dates:,
            observations: required_dates.map { |date| HistoricalExchangeRate.new(rate_date: date) }
          )
        else
          CoverageCalculator.for(required_dates:, observations: observations + inverse_observations, carry_forward: true)
        end
        present = coverage.complete?

        entry_for(
          code: present ? :exchange_rate : :missing_exchange_rate,
          status: present ? :healthy : coverage.partial? ? :partial : :missing,
          severity: present ? nil : :warning,
          subject: currency,
          description: present ? "Historical #{currency}/#{reporting_currency} rates are available." :
            "Historical #{currency}/#{reporting_currency} rates are missing for #{format_ranges(coverage.missing_ranges)}.",
          target: Target.new(
            kind: :historical_exchange_rates,
            base_currency: currency,
            quote_currency: reporting_currency
          ),
          actions: present ? [] : [ :retry ], coverage: coverage
        )
      end
    end

    def current_exchange_rate_entries
      foreign_currencies.map do |currency|
        lookup = current_exchange_rate_service.read(
          base_currency: currency, quote_currency: owner.reporting_currency
        )
        status = lookup.fresh? ? :healthy : lookup.stale? ? :stale : :missing
        present = status == :healthy
        entry_for(
          code: present ? :current_exchange_rate : :missing_current_exchange_rate,
          status:, severity: present ? nil : :warning, subject: currency,
          description: current_exchange_rate_description(currency:, status:),
          target: Target.new(kind: :current_exchange_rate,
            base_currency: currency, quote_currency: owner.reporting_currency),
          actions: present ? [] : [ :retry ]
        )
      end
    end

    def foreign_currencies
      @foreign_currencies ||= instruments.filter_map do |instrument|
        next unless instrument.currency != owner.reporting_currency && Position.for(instrument:).open?

        instrument.currency
      end.uniq
    end

    def current_exchange_rate_description(currency:, status:)
      pair = "#{currency}/#{owner.reporting_currency}"
      return "Current #{pair} exchange rate is available." if status == :healthy
      return "Current #{pair} exchange rate is stale; refresh it to update valuation." if status == :stale

      "Current #{pair} exchange rate is unavailable."
    end

    def benchmark_entries
      MarketBenchmark.find_each.map do |benchmark|
        first_date = owner.trades.minimum(:traded_on) || historical_end_date
        required_dates = TradingCalendar.weekdays_between(first_date, historical_end_date)
        observations = benchmark.observations.where(
          observed_on: (HistoricalObservationWindow.for(required_dates.min).begin..historical_end_date)
        ).to_a
        coverage = CoverageCalculator.for(required_dates:, observations:, carry_forward: true)
        present = coverage.complete?
        entry_for(
          code: present ? :benchmark_data : :missing_benchmark_data,
          status: present ? :healthy : coverage.partial? ? :partial : :missing,
          severity: present ? nil : :warning,
          subject: benchmark,
          description: present ? "#{benchmark.name} has stored observations." :
            "#{benchmark.name} (#{benchmark.identifier}) is missing observations for #{format_ranges(coverage.missing_ranges)}.",
          target: Target.new(kind: :benchmark_observations, record_id: benchmark.id),
          actions: present ? [] : [ :retry ], coverage: coverage
        )
      end
    end

    def performance_entries
      materialization = PortfolioPerformanceMaterialization.find_by(
        user: owner, reporting_currency: owner.reporting_currency
      )
      return [] unless materialization

      first_date = owner.trades.minimum(:traded_on)
      return [] unless first_date

      required_dates = (first_date..today).to_a
      observations = owner.portfolio_performance_observations.where(
        reporting_currency: owner.reporting_currency, observed_on: (first_date..today)
      ).to_a
      coverage = CoverageCalculator.for(required_dates:, observations:)
      status = if materialization.pending?
        :updating
      elsif coverage.complete?
        :healthy
      elsif coverage.partial?
        :partial
      else
        :missing
      end
      [ entry_for(
        code: :portfolio_performance, status:, severity: %i[missing partial].include?(status) ? :warning : nil,
        subject: "Portfolio performance", description: performance_description(coverage),
        target: Target.new(kind: :portfolio_performance), actions: status == :healthy ? [] : [ :retry ],
        coverage:
      ) ]
    end

    def performance_description(coverage)
      return "Portfolio performance is up to date." if coverage.complete?

      "Portfolio performance is missing values for #{format_ranges(coverage.missing_ranges)}."
    end

    def format_ranges(ranges)
      ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
    end

    def historical_end_date
      @historical_end_date ||= if TradingCalendar.weekend?(today)
        TradingCalendar.previous_business_day(today + 1.day)
      else
        TradingCalendar.previous_business_day(today)
      end
    end

    def entry_for(code:, target:, subject:, status:, severity:, description:, actions: [ :retry ], coverage: nil)
      Entry.new(
        code:, target:, subject:, status:, severity:, label: subject_label(subject), description:,
        observed_on: nil, fetched_at: nil, covered_range: coverage&.covered_range,
        missing_range: coverage&.missing_range, actions:
      )
    end

    def subject_label(subject)
      return "#{subject.ticker} · #{subject.name}" if subject.respond_to?(:ticker)
      return "#{subject.name} (#{subject.identifier})" if subject.respond_to?(:identifier)

      subject.to_s
    end
  end
end
