MoneyRails.configure do |config|
  config.default_currency = Rails.application.config.x.local_folio.reporting_currency
  config.raise_error_on_money_parsing = true
end
