module ApplicationHelper
  def format_quantity(quantity)
    format_decimal(quantity, minimum_precision: 0, maximum_precision: 8)
  end

  def format_unit_price(trade)
    currency = Money::Currency.find(trade.currency)
    "#{currency.symbol}#{format_decimal(trade.unit_price, minimum_precision: 2, maximum_precision: 8)}"
  end

  def format_unit_price_input(unit_price)
    format_decimal(unit_price, minimum_precision: 2, maximum_precision: 8)
  end

  private

  def format_decimal(value, minimum_precision:, maximum_precision:)
    whole, fraction = value.to_d.round(maximum_precision).to_s("F").split(".", 2)
    fraction = fraction.to_s.sub(/0+\z/, "").ljust(minimum_precision, "0")
    number = number_with_delimiter(whole)

    fraction.present? ? "#{number}.#{fraction}" : number
  end
end
