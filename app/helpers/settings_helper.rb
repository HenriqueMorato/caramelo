module SettingsHelper
  def reporting_currency_options
    ReportingCurrency::SUPPORTED_CODES.map do |code|
      currency = Money::Currency.find(code)
      [ "#{code} — #{currency.name}", code ]
    end
  end
end
