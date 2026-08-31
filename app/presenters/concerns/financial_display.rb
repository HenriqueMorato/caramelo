module FinancialDisplay
  private

  def signed_money(value)
    return unless value

    "#{positive?(value) ? "+" : ""}#{value.format}"
  end

  def signed_percentage(value)
    return unless value

    "#{positive?(value) ? "+" : ""}#{ActiveSupport::NumberHelper.number_to_percentage(value * 100, precision: 2)}"
  end

  def trend_arrow(value)
    return unless value

    positive?(value) ? "↑" : negative?(value) ? "↓" : "→"
  end

  def trend_color_class(value)
    negative?(value) ? "text-guava" : "text-leaf"
  end

  def side_label(trade)
    I18n.t(trade.buy? ? "Buy" : "Sell")
  end

  def side_color_class(trade)
    trade.buy? ? "bg-leaf" : "bg-guava"
  end

  def positive?(value)
    value.respond_to?(:positive?) && value.positive?
  end

  def negative?(value)
    value.respond_to?(:negative?) && value.negative?
  end
end
