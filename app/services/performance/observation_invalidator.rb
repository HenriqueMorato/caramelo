module Performance
  class ObservationInvalidator
    def self.mark!(user:, from:)
      currencies = user.portfolio_performance_materializations.pluck(:reporting_currency)
      currencies |= [ user.reporting_currency ]
      currencies.sort.each { |reporting_currency| new(user:, from:, reporting_currency:).mark! }
    end

    def self.enqueue(user:, from:)
      new(user:, from:).enqueue
    end

    def initialize(user:, from:, reporting_currency: user.reporting_currency,
      store: ObservationStore.new(user:, reporting_currency:), refresher: SeriesRefresh,
      materialization: PortfolioPerformanceMaterialization.for(user:, reporting_currency:))
      @user = user
      @from = from
      @store = store
      @refresher = refresher
      @materialization = materialization
    end

    def mark!
      return :future unless from <= Date.current

      materialization.request!(from:, to: Date.current, source_changed: true)
      return clear_observations unless user.trades.exists?

      store.stale_from(from)
      :stale
    end

    def enqueue
      return :future unless from <= Date.current

      refresher.enqueue(user:, from:, to: Date.current, reporting_currency: materialization.reporting_currency)
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { user_id: user.id, from: })
      :failed
    end

    private

    attr_reader :user, :from, :store, :refresher, :materialization

    def clear_observations
      store.delete_all
      :cleared
    end
  end
end
