module InstrumentPerformance
  class StartupPreparation
    def self.call(user: User.owner)
      new(user:).call
    end

    def initialize(user:)
      @user = user
    end

    def call
      instruments_with_activity.each do |instrument, first_activity|
        [ instrument.currency, user.reporting_currency ].uniq.each do |reporting_currency|
          Performance::SeriesRefresh.enqueue(
            user:, instrument:, reporting_currency:, from: first_activity, to: Date.current
          )
        end
      end
    end

    private

    attr_reader :user

    def instruments_with_activity
      starts = user.trades.where(traded_on: ..Date.current).group(:instrument_id).minimum(:traded_on)
      action_starts = user.corporate_actions.effective
        .where("COALESCE(ex_date, paid_on) <= ?", Date.current)
        .group_by(&:instrument_id)
        .transform_values { |actions| actions.map(&:performance_on).min }
      starts.merge!(action_starts) do |_instrument_id, trade_date, action_date|
        [ trade_date, action_date ].min
      end
      Instrument.where(id: starts.keys).index_with { |instrument| starts.fetch(instrument.id) }
    end
  end
end
