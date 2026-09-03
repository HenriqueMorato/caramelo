module MarketData
  class HealthReport
    Issue = Data.define(:code, :severity, :subject, :details) do
      def subject_label
        return "#{subject.ticker} · #{subject.name}" if subject.respond_to?(:ticker)
        return "#{subject.name} (#{subject.identifier})" if subject.respond_to?(:identifier)

        subject.to_s
      end
    end
    Result = Data.define(:checked_at, :issues) do
      def healthy? = issues.empty?
      def errors = issues.select { |issue| issue.severity == :error }
      def warnings = issues.select { |issue| issue.severity == :warning }
      def current_prices_need_refresh?
        issues.any? { |issue| %i[missing_current_price stale_current_price].include?(issue.code) }
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
      issues = instrument_issues + currency_issues + benchmark_issues
      Result.new(checked_at: Time.current, issues: issues.sort_by { |issue| issue.severity == :error ? 0 : 1 })
    end

    private

    attr_reader :owner, :current_market_price_service, :today

    def instruments
      @instruments ||= owner.trades.includes(:instrument).map(&:instrument).uniq
    end

    def instrument_issues
      instruments.flat_map do |instrument|
        issues = []
        lookup = current_market_price_service.read(instrument:)
        if lookup.nil? || lookup.missing?
          issues << Issue.new(code: :missing_current_price, severity: :error, subject: instrument,
            details: "#{instrument.ticker} has no current market price available.")
        elsif lookup.stale?
          issues << Issue.new(code: :stale_current_price, severity: :warning, subject: instrument,
            details: "#{instrument.ticker} has a stale current market price; refresh it to update valuation.")
        end

        unless instrument.daily_closing_prices.where(trading_date: ..today).exists?
          issues << Issue.new(code: :missing_daily_close, severity: :warning, subject: instrument,
            details: "#{instrument.ticker} has no historical closing price stored for the portfolio period.")
        end
        issues
      end
    end

    def currency_issues
      currencies = owner.trades.distinct.pluck(:currency)
      reporting_currency = Rails.configuration.x.local_folio.reporting_currency
      currencies.filter_map do |currency|
        next if currency == reporting_currency
        next if HistoricalExchangeRate.where(base_currency: currency, quote_currency: reporting_currency).exists?

        Issue.new(code: :missing_exchange_rate, severity: :warning, subject: currency,
          details: "No historical #{currency}/#{reporting_currency} rates are stored for portfolio performance.")
      end
    end

    def benchmark_issues
      MarketBenchmark.find_each.filter_map do |benchmark|
        next if benchmark.observations.where(observed_on: ..today).exists?

        Issue.new(code: :missing_benchmark_data, severity: :warning, subject: benchmark,
          details: "#{benchmark.name} (#{benchmark.identifier}) has no stored observations.")
      end
    end
  end
end
