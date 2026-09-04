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
        return if entry.healthy?

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

    def self.for(owner: User.owner, current_market_price_service: MarketPrice::Service.default, today: Date.current)
      new(owner:, current_market_price_service:, today:).call
    end

    def initialize(owner:, current_market_price_service:, today:)
      @owner = owner
      @current_market_price_service = current_market_price_service
      @today = today
    end

    def call
      entries = (instrument_entries + currency_entries + benchmark_entries)
        .sort_by { |entry| entry.severity == :error ? 0 : entry.severity == :warning ? 1 : 2 }
      Result.new(checked_at: Time.current, entries: entries)
    end

    private

    attr_reader :owner, :current_market_price_service, :today

    def instruments
      @instruments ||= owner.trades.includes(:instrument).map(&:instrument).uniq
    end

    def instrument_entries
      instruments.flat_map do |instrument|
        [ current_price_entry(instrument), daily_close_entry(instrument) ]
      end
    end

    def current_price_entry(instrument)
      lookup = current_market_price_service.read(instrument:)
      refresh_state = RefreshStatus::State.read("current_market_price:#{instrument.id}")
      if refreshing_state?(refresh_state)
        entry_for(
          code: :updating_current_price, status: :updating, severity: nil, subject: instrument,
          description: "#{instrument.ticker} is being refreshed.",
          target: Target.new(kind: :current_price, record_id: instrument.id), actions: []
        )
      elsif lookup.nil? || lookup.missing?
        entry_for(
          code: :missing_current_price, status: :missing, severity: :error, subject: instrument,
          description: "#{instrument.ticker} has no current market price available.",
          target: Target.new(kind: :current_price, record_id: instrument.id)
        )
      elsif lookup.stale?
        entry_for(
          code: :stale_current_price, status: :stale, severity: :warning, subject: instrument,
          description: "#{instrument.ticker} has a stale current market price; refresh it to update valuation.",
          target: Target.new(kind: :current_price, record_id: instrument.id)
        )
      else
        entry_for(
          code: :current_price, status: :healthy, severity: nil, subject: instrument,
          description: "#{instrument.ticker} has a current market price.",
          target: Target.new(kind: :current_price, record_id: instrument.id), actions: []
        )
      end
    end

    def daily_close_entry(instrument)
      present = instrument.daily_closing_prices.where(trading_date: ..today).exists?
      entry_for(
        code: present ? :daily_close : :missing_daily_close,
        status: present ? :healthy : :missing,
        severity: present ? nil : :warning,
        subject: instrument,
        description: present ? "#{instrument.ticker} has historical closing prices." :
          "#{instrument.ticker} has no historical closing price stored for the portfolio period.",
        target: Target.new(kind: :daily_closing_prices, record_id: instrument.id),
        actions: present ? [] : [ :retry ]
      )
    end

    def refreshing_state?(state)
      state&.running? && state.updated_at && state.updated_at > RefreshStatus::State::ACTIVE_TIMEOUT.ago
    end

    def currency_entries
      currencies = owner.trades.distinct.pluck(:currency)
      reporting_currency = owner.reporting_currency
      currencies.map do |currency|
        present = currency == reporting_currency || HistoricalExchangeRate.where(
          base_currency: currency, quote_currency: reporting_currency
        ).exists?

        entry_for(
          code: present ? :exchange_rate : :missing_exchange_rate,
          status: present ? :healthy : :missing,
          severity: present ? nil : :warning,
          subject: currency,
          description: present ? "Historical #{currency}/#{reporting_currency} rates are available." :
            "No historical #{currency}/#{reporting_currency} rates are stored for portfolio performance.",
          target: Target.new(
            kind: :historical_exchange_rates,
            base_currency: currency,
            quote_currency: reporting_currency
          ),
          actions: present ? [] : [ :retry ]
        )
      end
    end

    def benchmark_entries
      MarketBenchmark.find_each.map do |benchmark|
        present = benchmark.observations.where(observed_on: ..today).exists?
        entry_for(
          code: present ? :benchmark_data : :missing_benchmark_data,
          status: present ? :healthy : :missing,
          severity: present ? nil : :warning,
          subject: benchmark,
          description: present ? "#{benchmark.name} has stored observations." :
            "#{benchmark.name} (#{benchmark.identifier}) has no stored observations.",
          target: Target.new(kind: :benchmark_observations, record_id: benchmark.id),
          actions: present ? [] : [ :retry ]
        )
      end
    end

    def entry_for(code:, target:, subject:, status:, severity:, description:, actions: [ :retry ])
      Entry.new(
        code:, target:, subject:, status:, severity:, label: subject_label(subject), description:,
        observed_on: nil, fetched_at: nil, covered_range: nil, missing_range: nil, actions:
      )
    end

    def subject_label(subject)
      return "#{subject.ticker} · #{subject.name}" if subject.respond_to?(:ticker)
      return "#{subject.name} (#{subject.identifier})" if subject.respond_to?(:identifier)

      subject.to_s
    end
  end
end
