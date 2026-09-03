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
      source_generation = materialization.reload.source_generation
      records = store.read(from:, to:)
      dates = (from..to).to_a
      dates_to_build = dates.select do |date|
        record = records[date]
        record.nil? || record.stale? || record.source_generation != source_generation
      end
      if dates_to_build.empty?
        return Result.new(from:, to:, built_count: 0, skipped_count: dates.length, source_generation:)
      end

      trades = user.trades.includes(:instrument).strict_loading.order(:traded_on, :id).to_a
      if trades.empty?
        materialization.with_lock do
          store.delete_all if materialization.source_generation == source_generation
        end
        return Result.new(from:, to:, built_count: 0, skipped_count: dates.length, source_generation:)
      end

      built_count = 0
      dates_to_build.each do |date|
        valuation = portfolio.for(
          valuation_date: date, owner: user, trades:, reporting_currency: materialization.reporting_currency
        )
        break unless publish(valuation, source_generation:)

        built_count += 1
      end

      Result.new(
        from:, to:, built_count:,
        skipped_count: dates.length - dates_to_build.length, source_generation:
      )
    end

    private

    attr_reader :user, :store, :portfolio, :materialization

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
