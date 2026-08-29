require "bigdecimal"
require "json"
require "open3"
require "tempfile"
require "time"
require "uri"

module MarketData
  module YahooFinance
    DEFAULT_EXECUTABLE = "curl_chrome146"
    MARKET_PROVIDER_IDENTIFIER = "yahoo_finance"
    FX_PROVIDER_IDENTIFIER = "yahoo_finance_fx"
  end
end

require_relative "yahoo_finance/error"
require_relative "yahoo_finance/response"
require_relative "yahoo_finance/identifier"
require_relative "yahoo_finance/currency_pair"
require_relative "yahoo_finance/configuration"
require_relative "yahoo_finance/quote"
require_relative "yahoo_finance/curl_transport"
require_relative "yahoo_finance/base_client"
require_relative "yahoo_finance/quote_client"
require_relative "yahoo_finance/history_client"
require_relative "yahoo_finance/fx_history_client"

module MarketData
  module YahooFinance
    MARKET_CONFIGURATION = Configuration.new(
      identifier: MARKET_PROVIDER_IDENTIFIER, timeout: 15,
      interval_environment_variable: "YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS"
    )
    FX_CONFIGURATION = Configuration.new(
      identifier: FX_PROVIDER_IDENTIFIER, timeout: 10,
      interval_environment_variable: "YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS"
    )
    MARKET_TIMEOUT = MARKET_CONFIGURATION.timeout
    FX_TIMEOUT = FX_CONFIGURATION.timeout
  end
end
