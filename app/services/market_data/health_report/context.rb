module MarketData
  class HealthReport
    class Context
      attr_reader :owner, :today, :trades, :corporate_actions, :instruments, :performance_instruments,
        :currencies, :first_trade_date, :first_performance_date

      def initialize(owner:, today:)
        @owner = owner
        @today = today
        @trades = owner.trades.includes(:instrument).order(:traded_on, :id).to_a
        @corporate_actions = owner.corporate_actions.effective_on_or_before(today)
          .includes(:instrument).order(:paid_on, :id).to_a
        @instruments = trades.map(&:instrument).uniq
        @performance_instruments = (instruments + corporate_actions.map(&:instrument)).uniq
        @currencies = trades.map(&:currency).uniq
        @first_trade_date = trades.first&.traded_on
        @first_performance_dates = performance_dates_by_instrument
        @first_performance_date = @first_performance_dates.values.min
      end

      def first_performance_date_for(instrument)
        @first_performance_dates[instrument.id]
      end

      def reporting_currency
        owner.reporting_currency
      end

      private

      def performance_dates_by_instrument
        trade_dates = trades.group_by(&:instrument_id).transform_values { |records| records.map(&:traded_on).min }
        action_dates = corporate_actions.group_by(&:instrument_id)
          .transform_values { |records| records.map(&:performance_on).min }
        trade_dates.merge(action_dates) { |_instrument_id, trade_date, action_date| [ trade_date, action_date ].min }
      end
    end
  end
end
