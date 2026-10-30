class PortfolioPlansController < ApplicationController
  before_action :require_money_values_visible
  before_action :set_plan

  def show
    prepare_view
  rescue ArgumentError => error
    @calculation_error = error.message
    prepare_view
  end

  def new_group
    prepare_position_view
    asset_type_key = AssetType.normalize_key(params[:asset_type_key])
    position_results = available_group_positions(asset_type_key)
    return head :unprocessable_content unless AssetType.valid_key?(asset_type_key) && position_results.length >= 2

    group_key = "new_#{asset_type_key}"
    respond_to do |format|
      format.turbo_stream do
        group_key = "#{group_key}_#{SecureRandom.hex(4)}"
        render turbo_stream: turbo_stream.append(
          "portfolio-allocation-groups-#{asset_type_key}",
          partial: "portfolio_plans/allocation_group",
          locals: {
            group: nil,
            group_key:,
            asset_type_key:,
            position_results:,
            submitted: nil
          }
        )
      end
      format.html do
        @submitted_groups = { group_key => { "asset_type_key" => asset_type_key } }
        prepare_view
        render :show
      end
    end
  end

  def update
    allocation = allocation_params
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: current_account,
      asset_targets: allocation[:asset_targets] || {},
      instrument_targets: allocation[:instrument_targets] || {},
      groups: allocation[:groups] || {}
    )
    if result.success?
      redirect_to portfolio_plan_path(
        mode: calculation_params[:mode], contribution: calculation_params[:contribution],
        instrument_count: calculation_params[:instrument_count]
      ), notice: t("portfolio_plans.notices.Saved"), status: :see_other
    else
      @submitted_asset_targets = allocation[:asset_targets].to_h
      @submitted_instrument_targets = allocation[:instrument_targets].to_h
      @submitted_groups = allocation[:groups].to_h
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
    prepare_position_view
    @groups = @open_position_results.group_by { |result| result.instrument.asset_type }
    @groups = @groups.sort_by { |asset_type_key, _| AssetType.label_for(asset_type_key) }
    @asset_targets = @plan.asset_targets.index_by(&:asset_type_key)
    @instrument_targets = @plan.instrument_targets.index_by(&:instrument_id)
    @mode = calculation_params[:mode].to_s.in?(PortfolioAllocation::Calculator::MODES) ? calculation_params[:mode].to_s : "buy_only"
    @contribution = calculation_params[:contribution].presence || "0"
    @instrument_count = calculation_params[:instrument_count].to_s
    @instrument_count_limit = @open_position_results.length
    @calculation = PortfolioAllocation::Calculator.for(
      plan: @plan, owner: current_account, contribution: @contribution, mode: @mode,
      instrument_count: calculation_params[:instrument_count]
    ) unless @calculation_error
  end

  def prepare_position_view
    @position_results = Position.overview(owner: current_account)
    @open_position_results = @position_results.select { |result| result.position&.open? }
    @allocation_groups = @plan.allocation_groups.includes(:members).to_a
    @grouped_instrument_ids = @allocation_groups.flat_map { |group| group.members.map(&:instrument_id) }
  end

  def available_group_positions(asset_type_key)
    @open_position_results.select do |result|
      result.instrument.asset_type == asset_type_key && !@grouped_instrument_ids.include?(result.instrument.id)
    end
  end

  def allocation_params
    params.require(:portfolio_allocation).permit(
      asset_targets: {}, instrument_targets: {}, groups: {}
    )
  end

  def calculation_params
    params.permit(:mode, :contribution, :instrument_count)
  end
end
