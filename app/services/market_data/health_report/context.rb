module MarketData
  class HealthReport
    class Context
      attr_reader :owner, :today, :trades, :instruments, :currencies, :first_trade_date

      def initialize(owner:, today:)
        @owner = owner
        @today = today
        @trades = owner.trades.includes(:instrument).order(:traded_on, :id).to_a
        @instruments = trades.map(&:instrument).uniq
        @currencies = trades.map(&:currency).uniq
        @first_trade_date = trades.first&.traded_on
      end

      def reporting_currency
        owner.reporting_currency
      end
    end
  end
end
