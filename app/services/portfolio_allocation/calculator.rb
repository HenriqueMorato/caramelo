module PortfolioAllocation
  class Calculator
    CASH_RESERVE_RATIO = BigDecimal("0.01")
    MODES = %w[buy_only full_rebalance].freeze

    Comparison = Data.define(
      :instrument, :asset_type_key, :asset_percentage, :instrument_percentage,
      :target_percentage, :current_amount, :current_percentage, :target_amount,
      :difference_amount, :price_amount, :quantity_step, :action, :quantity,
      :estimated_amount
    ) do
      def buy? = action == :buy
      def sell? = action == :sell
      def none? = action == :none
      def overweight? = difference_amount.negative?
      def below_minimum? = (buy? || sell?) && quantity.zero?
    end

    Result = Data.define(
      :status, :mode, :currency, :current_amount, :contribution_amount,
      :investable_amount, :reserve_amount, :projected_amount, :comparisons,
      :unallocated_amount, :issues
    ) do
      def available? = status == :available
      def empty? = status == :empty
      def incomplete? = status == :incomplete
      def unconfigured? = status == :unconfigured
      def recommendations = comparisons.reject(&:none?)
    end

    def self.for(plan:, owner:, contribution: 0, mode: "buy_only", reporting_currency: owner.reporting_currency,
      market_price_service: MarketPrice::Service.default,
      exchange_rate_service: ExchangeRate::Service.default, snapshot: nil)
      new(
        plan:, owner:, contribution:, mode:, reporting_currency:,
        market_price_service:, exchange_rate_service:, snapshot:
      ).call
    end

    def initialize(plan:, owner:, contribution:, mode:, reporting_currency:, market_price_service:, exchange_rate_service:, snapshot:)
      @plan = plan
      @owner = owner
      @contribution = parse_contribution(contribution)
      @mode = mode.to_s.in?(MODES) ? mode.to_s : "buy_only"
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
      @market_price_service = market_price_service
      @exchange_rate_service = exchange_rate_service
      @snapshot = snapshot
    end

    def call
      return unconfigured_result unless plan.configured?

      snapshot = @snapshot ||= CurrentSnapshot.for(
        owner:, reporting_currency:, market_price_service:, exchange_rate_service:
      )
      return empty_result(snapshot) if snapshot.empty?
      return incomplete_result(snapshot) unless snapshot.available?
      closed_targets = closed_target_issues(snapshot)
      return incomplete_result(snapshot, issues: closed_targets) if closed_targets.any?

      comparisons = build_comparisons(snapshot)
      Result.new(
        :available, mode, reporting_currency, snapshot.total_amount, contribution,
        investable_amount, reserve_amount, projected_amount, comparisons,
        unallocated_amount(comparisons), []
      )
    end

    private

    attr_reader :plan, :owner, :contribution, :mode, :reporting_currency,
      :market_price_service, :exchange_rate_service

    def parse_contribution(value)
      decimal = BigDecimal(value.to_s.strip)
      raise ArgumentError, "contribution must be nonnegative" if decimal.negative?

      decimal
    rescue ArgumentError => error
      raise error if error.message == "contribution must be nonnegative"

      raise ArgumentError, "contribution is invalid"
    end

    def investable_amount
      contribution * (BigDecimal("1") - CASH_RESERVE_RATIO)
    end

    def reserve_amount
      contribution - investable_amount
    end

    def projected_amount
      current_amount + investable_amount
    end

    def current_amount
      @current_amount ||= @snapshot.total_amount
    end

    def asset_percentages
      @asset_percentages ||= plan.asset_targets.to_h do |target|
        [ target.asset_type_key, target.target_percentage.to_d ]
      end
    end

    def instrument_percentages
      @instrument_percentages ||= plan.instrument_targets.group_by(&:asset_type_key).transform_values do |targets|
        targets.to_h { |target| [ target.instrument_id, target.target_percentage.to_d ] }
      end
    end

    def instrument_percentage_for(instrument, holdings)
      configured = instrument_percentages[instrument.asset_type]
      holding_ids = holdings.map { |holding| holding.instrument.id }
      available_count = holdings.count { |holding| holding.instrument.asset_type == instrument.asset_type }
      return BigDecimal("100") / available_count if configured.blank?

      explicit = configured[instrument.id]
      return explicit if explicit

      remainder = BigDecimal("100") - configured.values.sum
      omitted_count = available_count - configured.keys.count { |id| holding_ids.include?(id) }
      return BigDecimal("0") unless remainder.positive? && omitted_count.positive?

      remainder / omitted_count
    end

    def target_percentage_for(instrument, instrument_percentage:)
      asset_percentage = asset_percentages[instrument.asset_type]
      return BigDecimal("0") unless asset_percentage && instrument_percentage

      asset_percentage * instrument_percentage / BigDecimal("10000")
    end

    def build_comparisons(snapshot)
      raw = snapshot.holdings.map do |holding|
        asset_percentage = asset_percentages[holding.instrument.asset_type] || BigDecimal("0")
        instrument_percentage = instrument_percentage_for(holding.instrument, snapshot.holdings)
        target_percentage = target_percentage_for(holding.instrument, instrument_percentage:)
        current_percentage = holding.market_value_amount / snapshot.total_amount * BigDecimal("100")
        target_amount = projected_amount * target_percentage
        difference_amount = target_amount - holding.market_value_amount
        [ holding, asset_percentage, instrument_percentage, target_percentage,
          current_percentage, target_amount, difference_amount ]
      end

      if mode == "buy_only"
        buy_allocations = buy_allocations(raw)
      end

      raw.map do |holding, asset_percentage, instrument_percentage, target_percentage,
        current_percentage, target_amount, difference_amount|
        requested_amount = if mode == "buy_only"
          buy_allocations.fetch(holding.instrument.id, BigDecimal("0"))
        else
          difference_amount
        end
        comparison_for(
          holding:, asset_percentage:, instrument_percentage:, target_percentage:,
          current_percentage:, target_amount:, difference_amount:, requested_amount:
        )
      end
    end

    def buy_allocations(raw)
      positive = raw.select { |_holding, _asset, _instrument, _target, _current, _amount, difference| difference.positive? }
      total = positive.sum { |values| values.last }
      return {} if total.zero? || investable_amount.zero?

      positive.to_h do |holding, *_values, difference|
        [ holding.instrument.id, investable_amount * difference / total ]
      end
    end

    def comparison_for(holding:, asset_percentage:, instrument_percentage:, target_percentage:,
      current_percentage:, target_amount:, difference_amount:, requested_amount:)
      action = if requested_amount.positive?
        :buy
      elsif requested_amount.negative?
        :sell
      else
        :none
      end
      amount = requested_amount.abs
      quantity = floor_to_step(amount / holding.price_amount, holding.instrument.quantity_step.to_d)
      estimated_amount = quantity * holding.price_amount
      Comparison.new(
        holding.instrument, holding.instrument.asset_type, asset_percentage, instrument_percentage,
        target_percentage * BigDecimal("100"), holding.market_value_amount,
        current_percentage, target_amount, difference_amount, holding.price_amount,
        holding.instrument.quantity_step.to_d, action, quantity, estimated_amount
      )
    end

    def floor_to_step(value, step)
      return BigDecimal("0") unless value.positive?

      (value / step).floor * step
    end

    def unallocated_amount(comparisons)
      return BigDecimal("0") if mode == "full_rebalance"

      investable_amount - comparisons.sum { |comparison| comparison.buy? ? comparison.estimated_amount : BigDecimal("0") }
    end

    def empty_result(snapshot)
      Result.new(:empty, mode, reporting_currency, BigDecimal("0"), contribution,
        investable_amount, reserve_amount, investable_amount, [], investable_amount, snapshot.issues)
    end

    def incomplete_result(snapshot, issues: snapshot.issues)
      Result.new(:incomplete, mode, reporting_currency, nil, contribution,
        investable_amount, reserve_amount, nil, [], nil, issues)
    end

    def closed_target_issues(snapshot)
      holding_ids = snapshot.holdings.map { |holding| holding.instrument.id }
      instruments = Instrument.where(id: plan.instrument_targets.pluck(:instrument_id)).index_by(&:id)
      plan.instrument_targets.filter_map do |target|
        next if holding_ids.include?(target.instrument_id)

        CurrentSnapshot::Issue.new(instruments.fetch(target.instrument_id), :closed)
      end
    end

    def unconfigured_result
      Result.new(:unconfigured, mode, reporting_currency, nil, contribution,
        investable_amount, reserve_amount, nil, [], investable_amount, [])
    end
  end
end
