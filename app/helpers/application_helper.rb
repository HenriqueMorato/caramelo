module ApplicationHelper
  MONEY_MASK = "••••••"

  def format_quantity(quantity)
    format_decimal(quantity, minimum_precision: 0, maximum_precision: 8)
  end

  def format_unit_price(trade)
    return hidden_money_value if money_values_hidden?

    currency = Money::Currency.find(trade.currency)
    "#{currency.symbol}#{format_decimal(trade.unit_price, minimum_precision: 2, maximum_precision: 8)}"
  end

  def format_currency_amount(amount, currency)
    display_money(Money.from_amount(amount, currency))
  end

  def display_money(value, fallback: t("Not available"))
    return fallback if value.nil?
    return hidden_money_value if money_values_hidden?

    value.respond_to?(:format) ? value.format : value
  end

  def value_or_not_available(value)
    value.nil? ? t("Not available") : value
  end

  def format_unit_price_input(unit_price)
    format_decimal(unit_price, minimum_precision: 2, maximum_precision: 8, delimiter: false)
  end

  private

  def hidden_money_value
    safe_join([
      tag.span(t("privacy.Value hidden"), class: "sr-only"),
      tag.span(MONEY_MASK, aria: { hidden: true })
    ])
  end

  def format_decimal(value, minimum_precision:, maximum_precision:, delimiter: true)
    whole, fraction = value.to_d.round(maximum_precision).to_s("F").split(".", 2)
    fraction = fraction.to_s.sub(/0+\z/, "").ljust(minimum_precision, "0")
    number = delimiter ? number_with_delimiter(whole) : whole

    fraction.present? ? "#{number}.#{fraction}" : number
  end
end
