module Performance
  class ObservationBuilder
    # Built days were published; skipped days were already fresh. The generation
    # lets completion distinguish this snapshot from a newer source edit.
    Result = Data.define(:from, :to, :built_count, :skipped_count, :source_generation)

    def initialize(user:, store: nil, portfolio: Portfolio,
      materialization: PortfolioPerformanceMaterialization.for(user:))
      @user = user
      @store = store || ObservationStore.new(user:, reporting_currency: materialization.reporting_currency)
      @portfolio = portfolio
      @materialization = materialization
    end

    def call(from:, to:)
      validate_range!(from:, to:)
      prepare_range(from:, to:)
      return result if dates_to_build.empty?

      if trades.empty?
        clear_observations
        return result
      end

      result(built_count: build_dates, skipped_count: dates.length - dates_to_build.length)
    end

    private

    attr_reader :user, :store, :portfolio, :materialization, :from, :to,
      :source_generation, :dates, :dates_to_build

    def prepare_range(from:, to:)
      @from = from
      @to = to
      @source_generation = materialization.reload.source_generation
      @dates = (from..to).to_a
      @trades = nil
      records = store.read(from:, to:)
      @dates_to_build = dates.select do |date|
        record = records[date]
        record.nil? || record.stale? || record.source_generation != source_generation
      end
    end

    def trades
      @trades ||= user.trades.includes(:instrument).strict_loading.order(:traded_on, :id).to_a
    end

    def build_dates
      built_count = 0
      dates_to_build.each do |date|
        valuation = portfolio.for(
          valuation_date: date, owner: user, trades:, reporting_currency: materialization.reporting_currency
        )
        break unless publish(valuation, source_generation:)

        built_count += 1
      end

      built_count
    end

    def clear_observations
      materialization.with_lock do
        store.delete_all if materialization.source_generation == source_generation
      end
    end

    def result(built_count: 0, skipped_count: dates.length)
      Result.new(from:, to:, built_count:, skipped_count:, source_generation:)
    end

    def publish(valuation, source_generation:)
      materialization.with_lock do
        # A source edit may commit while valuation is running. Never publish
        # its older snapshot over the newer durable invalidation.
        return false unless materialization.source_generation == source_generation

        store.write(valuation, source_generation:, generated_at: Time.current)
      end
      true
    end

    def validate_range!(from:, to:)
      return if from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current

      raise ArgumentError, "observation range must use past dates in chronological order"
    end
  end
end
