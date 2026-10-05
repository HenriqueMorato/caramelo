module CorporateActionImports
  module Providers
    YAHOO_FINANCE = MarketData::YahooFinance::MARKET_CONFIGURATION.identifier
    SUPPORTED_SOURCES = [ YAHOO_FINANCE ].freeze
  end
end
