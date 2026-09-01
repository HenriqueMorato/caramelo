class PositionsController < ApplicationController
  allow_unauthenticated_access

  def index
    @show_closed = params[:closed] == "1"
    @grouping = Position::Grouping.new(primary: params[:group_by], secondary: params[:subgroup_by])
    @group_by = @grouping.primary
    @subgroup_by = @grouping.secondary
    @position_results = Position.overview(include_institutions: @grouping.include_institutions?)
    @has_closed_positions = @position_results.any? { |result| result.position&.closed? }
    visible_results = @position_results.select do |result|
      result.invalid? || @show_closed || result.position.open?
    end
    @positions = visible_results.map do |position_result|
      Position::Presenter.for(position_result:)
    end
    @position_groups = @grouping.group(@positions)
    @has_refreshable_market_prices = @positions.any?(&:market_price_refreshable?)
  end

  private

  helper_method :grouping_label, :grouping_options, :grouping_slot

  def grouping_label(grouping, value) = @grouping.label(grouping, value)

  def grouping_options = @grouping.options

  def grouping_slot(value) = @grouping.slot(value)
end
