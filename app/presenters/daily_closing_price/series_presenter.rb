class DailyClosingPrice::SeriesPresenter
  attr_reader :observations, :currency

  def self.for(instrument:, from: 6.months.ago.to_date)
    observations = DailyClosingPrice
      .where(instrument:, provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier)
      .where(trading_date: from..Date.current)
      .chronological
      .load

    new(observations:, currency: instrument.currency)
  end

  def initialize(observations:, currency:)
    @observations = observations
    @currency = currency
  end

  def available?
    observations.size > 1
  end

  def chart_data
    {
      labels: observations.map { |observation| I18n.l(observation.trading_date, format: :short) },
      values: observations.map { |observation| observation.close_price.to_f },
      formatted_values: observations.map { |observation| Money.from_amount(observation.close_price, currency).format },
      label: I18n.t("instruments.show.Closing price"),
      currency:,
      locale: I18n.locale
    }
  end
end
