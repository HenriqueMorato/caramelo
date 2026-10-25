class PortfolioPlansController < ApplicationController
  before_action :require_money_values_visible
  before_action :set_plan

  def show
    prepare_view
  rescue ArgumentError => error
    @calculation_error = error.message
    prepare_view
  end

  def update
    allocation = allocation_params
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: current_account,
      asset_targets: allocation.fetch(:asset_targets, {}),
      instrument_targets: allocation.fetch(:instrument_targets, {})
    )
    if result.success?
      redirect_to portfolio_plan_path(
        mode: calculation_params[:mode], contribution: calculation_params[:contribution]
      ), notice: t("portfolio_plans.notices.Saved"), status: :see_other
    else
      @submitted_asset_targets = allocation.fetch(:asset_targets, {}).to_h
      @submitted_instrument_targets = allocation.fetch(:instrument_targets, {}).to_h
      result.errors.each { |message| @plan.errors.add(:base, message) }
      prepare_view
      render :show, status: :unprocessable_content
    end
  end

  private

  def set_plan
    @plan = current_account.portfolio_allocation_plan || current_account.create_portfolio_allocation_plan!
  end

  def prepare_view
    @position_results = Position.overview(owner: current_account)
    @open_position_results = @position_results.select { |result| result.position&.open? }
    @groups = @open_position_results.group_by { |result| result.instrument.asset_type }
    @groups = @groups.sort_by { |asset_type_key, _| AssetType.label_for(asset_type_key) }
    @asset_targets = @plan.asset_targets.index_by(&:asset_type_key)
    @instrument_targets = @plan.instrument_targets.index_by(&:instrument_id)
    @mode = calculation_params[:mode].to_s.in?(PortfolioAllocation::Calculator::MODES) ? calculation_params[:mode].to_s : "buy_only"
    @contribution = calculation_params[:contribution].presence || "0"
    @calculation = PortfolioAllocation::Calculator.for(
      plan: @plan, owner: current_account, contribution: @contribution, mode: @mode
    ) unless @calculation_error
  end

  def allocation_params
    params.require(:portfolio_allocation).permit(
      asset_targets: {}, instrument_targets: {}
    )
  end

  def calculation_params
    params.permit(:mode, :contribution)
  end
end
