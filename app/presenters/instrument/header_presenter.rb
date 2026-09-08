class Instrument::HeaderPresenter
  include FinancialDisplay

  attr_reader :instrument, :market_price

  def self.for(instrument:, market_price:)
    previous_close = previous_close_for(instrument:, market_price:)
    new(instrument:, market_price:, previous_close:)
  end

  def self.previous_close_for(instrument:, market_price:)
    current_market_price = market_price.current_market_price
    return unless current_market_price

    DailyClosingPrice
      .where(instrument:, provider: current_market_price.provider)
      .where(trading_date: ...current_market_price.quoted_at.to_date)
      .chronological
      .last
  end
  private_class_method :previous_close_for

  def initialize(instrument:, market_price:, previous_close:)
    @instrument = instrument
    @market_price = market_price.current_market_price
    @previous_close = previous_close
  end

  def ticker_mark
    instrument.ticker.first(4)
  end

  def asset_type_label
    I18n.t("instrument_types.#{instrument.asset_type}")
  end

  def price_label
    money(market_price&.unit_price)&.format
  end

  def day_change_label
    signed_money(day_change)
  end

  def day_change_ratio_label
    signed_percentage(day_change_ratio)
  end

  def day_change_arrow
    trend_arrow(day_change)
  end

  def day_change_color_class
    trend_color_class(day_change)
  end

  private

  attr_reader :previous_close

  def day_change
    return unless market_price && previous_close

    money(market_price.unit_price - previous_close.close_price)
  end

  def day_change_ratio
    return unless market_price && previous_close

    (market_price.unit_price - previous_close.close_price) / previous_close.close_price
  end

  def money(amount)
    Money.from_amount(amount, instrument.currency) if amount
  end
end
