module MarketData
  module YahooFinance
    Quote = Data.define(:symbol, :unit_price, :currency, :quoted_at)
  end
end
