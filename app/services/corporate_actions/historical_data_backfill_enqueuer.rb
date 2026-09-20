module CorporateActions
  class HistoricalDataBackfillEnqueuer
    def self.call(corporate_action:)
      new(corporate_action:).call
    end

    def initialize(corporate_action:)
      @corporate_action = corporate_action
    end

    def call
      return unless corporate_action.confirmed?

      HistoricalDataBackfill.enqueue_for(
        instrument: corporate_action.instrument,
        currency: corporate_action.instrument.currency,
        from_date: corporate_action.performance_on
      )
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { corporate_action_id: corporate_action.id })
    end

    private

    attr_reader :corporate_action
  end
end
