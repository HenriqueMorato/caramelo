class DailyClosingPrice::SeriesPresenter
  # One accessible chart row with its localized date and formatted closing price.
  Row = Data.define(:date, :price)

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
    presented_rows = rows

    {
      labels: presented_rows.map(&:date),
      values: observations.map { |observation| observation.close_price.to_f },
      formatted_values: presented_rows.map(&:price),
      label: I18n.t("instruments.show.Closing price"),
      currency:,
      locale: I18n.locale
    }
  end

  def rows
    observations.map do |observation|
      Row.new(
        date: I18n.l(observation.trading_date, format: :short),
        price: Money.from_amount(observation.close_price, currency).format
      )
    end
  end
end
