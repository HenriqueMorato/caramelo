module PortfolioAllocation
  class Calculator
    CASH_RESERVE_RATIO = BigDecimal("0.01")
    MODES = %w[buy_only full_rebalance].freeze

    Comparison = Data.define(
      :instrument, :asset_type_key, :asset_percentage, :instrument_percentage,
      :target_percentage, :current_amount, :current_percentage, :target_amount,
      :difference_amount, :price_amount, :quantity_step, :action, :quantity,
      :estimated_amount, :allocation_group, :purchase_policy
    ) do
      def buy? = action == :buy
      def sell? = action == :sell
      def none? = action == :none
      def overweight? = difference_amount.negative?
      def below_minimum? = (buy? || sell?) && quantity.zero?
      def over_target_after_purchase? = buy? && estimated_amount > difference_amount
      def overshoot_amount = over_target_after_purchase? ? estimated_amount - difference_amount : BigDecimal("0")
      def grouped? = allocation_group.present?
      def hold? = purchase_policy == "hold"
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
      def over_target? = comparisons.any?(&:over_target_after_purchase?)
    end

    def self.for(plan:, owner:, contribution: 0, mode: "buy_only", instrument_count: nil,
      reporting_currency: owner.reporting_currency,
      market_price_service: MarketPrice::Service.default,
      exchange_rate_service: ExchangeRate::Service.default, snapshot: nil)
      new(
        plan:, owner:, contribution:, mode:, instrument_count:, reporting_currency:,
        market_price_service:, exchange_rate_service:, snapshot:
      ).call
    end

    def initialize(plan:, owner:, contribution:, mode:, instrument_count:, reporting_currency:, market_price_service:, exchange_rate_service:, snapshot:)
      @plan = plan
      @owner = owner
      @contribution = parse_contribution(contribution)
      @mode = mode.to_s.in?(MODES) ? mode.to_s : "buy_only"
      @instrument_count = parse_instrument_count(instrument_count)
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

    attr_reader :plan, :owner, :contribution, :mode, :instrument_count, :reporting_currency,
      :market_price_service, :exchange_rate_service

    def parse_contribution(value)
      decimal = BigDecimal(value.to_s.strip)
      raise ArgumentError, "contribution must be nonnegative" if decimal.negative?

      decimal
    rescue ArgumentError => error
      raise error if error.message == "contribution must be nonnegative"

      raise ArgumentError, "contribution is invalid"
    end

    def parse_instrument_count(value)
      return nil if value.nil? || value.to_s.strip.empty?

      count = Integer(value.to_s, 10)
      raise ArgumentError, "instrument_count is invalid" unless count.positive?

      count
    rescue ArgumentError => error
      raise error if error.message == "instrument_count is invalid"

      raise ArgumentError, "instrument_count is invalid"
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
      configured = instrument_percentages[instrument.asset_type] || {}
      available_holdings = holdings.select { |holding| holding.instrument.asset_type == instrument.asset_type }
      groups = allocation_groups_by_asset_type.fetch(instrument.asset_type, [])
      ungrouped_holdings = available_holdings.reject { |holding| group_memberships.key?(holding.instrument.id) }
      return BigDecimal("100") / available_holdings.length if configured.blank? && groups.empty?

      explicit = configured[instrument.id]
      return explicit if explicit

      remainder = BigDecimal("100") - configured.values.sum - groups.sum(&:target_percentage)
      omitted_count = ungrouped_holdings.count { |holding| !configured.key?(holding.instrument.id) }
      return BigDecimal("0") unless remainder.positive? && omitted_count.positive?

      remainder / omitted_count
    end

    def target_percentage_for(instrument, instrument_percentage:)
      asset_percentage = asset_percentages[instrument.asset_type]
      return BigDecimal("0") unless asset_percentage && instrument_percentage

      asset_percentage * instrument_percentage / BigDecimal("10000")
    end

    def build_comparisons(snapshot)
      holdings_by_id = snapshot.holdings.index_by { |holding| holding.instrument.id }
      raw = snapshot.holdings.map do |holding|
        group, member = group_memberships[holding.instrument.id]
        asset_percentage = asset_percentages[holding.instrument.asset_type] || BigDecimal("0")
        current_percentage = holding.market_value_amount / snapshot.total_amount * BigDecimal("100")
        target_amount, instrument_percentage = if group
          [ grouped_target_amount(group, member, holdings_by_id), group.target_percentage.to_d ]
        else
          instrument_percentage = instrument_percentage_for(holding.instrument, snapshot.holdings)
          [ projected_amount * target_percentage_for(holding.instrument, instrument_percentage:), instrument_percentage ]
        end
        target_percentage = target_amount / projected_amount
        {
          holding:, asset_percentage:, instrument_percentage:, target_percentage:,
          current_percentage:, target_amount:, difference_amount: target_amount - holding.market_value_amount,
          allocation_group: group, purchase_policy: member&.purchase_policy
        }
      end

      buy_allocations = mode == "buy_only" ? buy_allocations(raw) : {}

      raw.map do |entry|
        holding = entry.fetch(:holding)
        difference_amount = entry.fetch(:difference_amount)
        requested_amount = if mode == "buy_only"
          buy_allocations.fetch(holding.instrument.id, BigDecimal("0"))
        else
          difference_amount
        end
        comparison_for(**entry, requested_amount:)
      end
    end

    def buy_allocations(raw)
      positive = raw.select { |entry| entry.fetch(:difference_amount).positive? }
      total = positive.sum { |entry| entry.fetch(:difference_amount) }
      return {} if total.zero? || investable_amount.zero?

      return planned_buy_allocations(positive) if instrument_count

      positive.to_h do |entry|
        [ entry.fetch(:holding).instrument.id, investable_amount * entry.fetch(:difference_amount) / total ]
      end
    end

    def planned_buy_allocations(positive)
      candidates = positive.map do |entry|
        PurchasePlanner::Candidate.new(
          holding: entry.fetch(:holding), target_gap: entry.fetch(:difference_amount)
        )
      end
      PurchasePlanner.for(candidates:, budget: investable_amount, count: instrument_count)
    end

    def comparison_for(holding:, asset_percentage:, instrument_percentage:, target_percentage:,
      current_percentage:, target_amount:, difference_amount:, allocation_group:,
      purchase_policy:, requested_amount:)
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
        holding.instrument.quantity_step.to_d, action, quantity, estimated_amount,
        allocation_group, purchase_policy
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
      target_instrument_ids = plan.instrument_targets.pluck(:instrument_id) +
        plan.allocation_groups.joins(:members).pluck("portfolio_allocation_group_members.instrument_id")
      instruments = Instrument.where(id: target_instrument_ids.uniq).index_by(&:id)
      target_instrument_ids.uniq.filter_map do |instrument_id|
        next if holding_ids.include?(instrument_id)

        CurrentSnapshot::Issue.new(instruments.fetch(instrument_id), :closed)
      end
    end

    def group_memberships
      @group_memberships ||= plan.allocation_groups.includes(:members).each_with_object({}) do |group, memberships|
        group.members.each { |member| memberships[member.instrument_id] = [ group, member ] }
      end
    end

    def allocation_groups_by_asset_type
      @allocation_groups_by_asset_type ||= plan.allocation_groups.group_by(&:asset_type_key)
    end

    def grouped_target_amount(group, member, holdings_by_id)
      target_amount = projected_amount * asset_percentages.fetch(group.asset_type_key, BigDecimal("0")) *
        group.target_percentage.to_d / BigDecimal("10000")
      return holdings_by_id.fetch(member.instrument_id).market_value_amount if member.hold?

      hold_amount = group.members.select(&:hold?).sum do |group_member|
        holdings_by_id.fetch(group_member.instrument_id).market_value_amount
      end
      buy_members = group.members.select(&:buy?)
      return BigDecimal("0") if buy_members.empty?

      available_amount = [ target_amount - hold_amount, BigDecimal("0") ].max
      available_amount / buy_members.length
    end

    def unconfigured_result
      Result.new(:unconfigured, mode, reporting_currency, nil, contribution,
        investable_amount, reserve_amount, nil, [], investable_amount, [])
    end
  end
end
