class CaptureHistoricalExchangeRatesJob < ApplicationJob
  queue_as :market_prices

  def perform(rate_date: nil)
    rate_date ||= TradingCalendar.previous_business_day

    targets = performance_targets
    RefreshStatus::Tracker.perform(scope: "historical_exchange_rates", total_count: targets.length) do |refresh|
      targets.each do |currency, quote_currency|
        next if HistoricalExchangeRate.exists?(
          base_currency: currency, quote_currency:, rate_date:,
          provider: HistoricalExchangeRate::Providers::YahooFinance::IDENTIFIER
        )

        throttle.wait!
        importer.call(
          base_currency: currency,
          quote_currency:,
          from: rate_date,
          to: rate_date,
          fence: publication_fence(currency:, quote_currency:)
        )
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { currency:, quote_currency:, rate_date: })
        RefreshStatus::Tracker.record_failure(refresh, error)
      ensure
        RefreshStatus::Tracker.advance(refresh)
      end
    end
  end

  private

  def importer
    @importer ||= HistoricalExchangeRate::Importer.default
  end

  def throttle
    @throttle ||= MarketData::YahooFinance::RequestThrottle.new
  end

  attr_reader :reporting_currency

  def performance_targets
    if Caramelo::AccountMode.single?
      @reporting_currency = User.default_owner.reporting_currency
      return performance_currencies.map { |currency| [ currency, reporting_currency ] }
    end

    reporting_currencies.flat_map do |quote_currency|
      performance_currencies_for(quote_currency).map { |currency| [ currency, quote_currency ] }
    end
  end

  def performance_currencies
    trade_currencies = Instrument.where(id: Trade.where(user: User.default_owner).select(:instrument_id)).pluck(:currency)
    income_currencies = CorporateAction.effective_on_or_before(Date.current)
      .where(user: User.default_owner).includes(:instrument).map { |action| action.currency || action.instrument.currency }
    benchmark_currencies = MarketBenchmark.where(kind: MarketBenchmark::PERFORMANCE_KINDS).distinct.pluck(:currency)
    (trade_currencies | income_currencies | benchmark_currencies).excluding(reporting_currency)
  end

  def reporting_currencies
    User.distinct.pluck(:reporting_currency)
  end

  def performance_currencies_for(quote_currency)
    trade_currencies = Instrument.where(id: Trade.distinct.select(:instrument_id)).pluck(:currency)
    income_currencies = CorporateAction.effective_on_or_before(Date.current)
      .includes(:instrument).map { |action| action.currency || action.instrument.currency }
    benchmark_currencies = MarketBenchmark.where(kind: MarketBenchmark::PERFORMANCE_KINDS).distinct.pluck(:currency)
    (trade_currencies | income_currencies | benchmark_currencies).excluding(quote_currency)
  end

  def publication_fence(currency:, quote_currency: reporting_currency)
    MarketData::PublicationFence.new(
      target: MarketData::Target.new(kind: :historical_exchange_rates,
        base_currency: currency, quote_currency:,
        provider: HistoricalExchangeRate::Providers::YahooFinance::IDENTIFIER)
    )
  end
end
