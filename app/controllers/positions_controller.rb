class PositionsController < ApplicationController
  GROUPING_OPTIONS = %w[asset_type institution currency exchange].freeze

  allow_unauthenticated_access

  def index
    @show_closed = params[:closed] == "1"
    @group_by = valid_grouping(params[:group_by])
    @subgroup_by = valid_grouping(params[:subgroup_by]) unless @group_by == valid_grouping(params[:subgroup_by])
    @position_results = Position.overview(include_institutions: [ @group_by, @subgroup_by ].include?("institution"))
    @has_closed_positions = @position_results.any? { |result| result.position&.closed? }
    visible_results = @position_results.select do |result|
      result.invalid? || @show_closed || result.position.open?
    end
    @positions = visible_results.map do |position_result|
      Position::Presenter.for(position_result:)
    end
    @position_groups = grouped_positions
    @has_refreshable_market_prices = @positions.any?(&:market_price_refreshable?)
  end

  private

  def valid_grouping(value)
    value.presence if GROUPING_OPTIONS.include?(value)
  end

  def grouped_positions
    return { nil => @positions } unless @group_by

    @positions.group_by { |position| grouping_value(position, @group_by) }.transform_values do |positions|
      @subgroup_by ? positions.group_by { |position| grouping_value(position, @subgroup_by) } : positions
    end
  end

  def grouping_value(position, grouping)
    return position.instrument.public_send(grouping) if %w[asset_type currency exchange].include?(grouping)

    names = position.position.trades.filter_map { |trade| trade.institution&.name }.uniq
    names.one? ? names.first : names.any? ? "Multiple institutions" : "No institution"
  end

  helper_method :grouping_label, :grouping_option_class, :grouping_options

  def grouping_option_class(value)
    return "border border-brand-700 bg-brand-700 text-white shadow-inner ring-1 ring-inset ring-white/60 hover:bg-brand-800" if value == @group_by
    return "border border-caramel-deep bg-caramel text-white shadow-inner ring-1 ring-inset ring-white/60 hover:bg-caramel-deep" if value == @subgroup_by

    "ui-button-secondary"
  end

  def grouping_options
    [ [ I18n.t("positions.index.No grouping"), "" ] ] + GROUPING_OPTIONS.map do |option|
      [ I18n.t("positions.index.Group by #{option}"), option ]
    end
  end

  def grouping_label(grouping, value)
    grouping == "asset_type" ? I18n.t("instrument_types.#{value}") : value
  end
end
