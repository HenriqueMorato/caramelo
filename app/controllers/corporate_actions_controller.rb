class CorporateActionsController < ApplicationController
  allow_unauthenticated_access

  before_action :set_corporate_action, only: %i[ edit update destroy ]
  before_action :set_return_to, only: %i[ edit update destroy ]
  before_action :set_context_instrument, only: %i[ new create ]
  before_action :set_form_options, only: %i[ new create edit update ]
  before_action :require_money_values_visible, only: %i[ new create edit update ]

  def new
    @corporate_action = owner.corporate_actions.new(
      instrument: @context_instrument,
      kind: :dividend,
      status: :confirmed,
      paid_on: Date.current,
      source: "manual"
    )
    @corporate_action.currency = @context_instrument.currency if @context_instrument
  end

  def create
    @corporate_action = owner.corporate_actions.new
    assign_corporate_action_attributes

    if @corporate_action.save
      enqueue_historical_data_backfill
      redirect_to transactions_path, notice: t("notices.Created", model: CorporateAction.model_name.human)
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    assign_corporate_action_attributes

    if @corporate_action.save
      enqueue_historical_data_backfill
      redirect_to @return_to,
        notice: t("notices.Updated", model: CorporateAction.model_name.human), status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @corporate_action.destroy!
    redirect_to @return_to,
      notice: t("notices.Deleted", model: CorporateAction.model_name.human), status: :see_other
  end

  private

  def owner
    @owner ||= User.owner
  end

  def set_corporate_action
    @corporate_action = owner.corporate_actions.friendly.find(params.expect(:id))
  end

  def set_return_to
    @return_to = url_from(params[:return_to]) || url_from(request.referer) || transactions_path
  end

  def set_context_instrument
    @context_instrument = Instrument.friendly.find(params[:instrument_id]) if params[:instrument_id]
  end

  def set_form_options
    @instruments = Instrument.alphabetical
    active_institution_ids = owner.institutions.active.select(:id)
    pairs = owner.trades.where(institution_id: active_institution_ids)
      .distinct.pluck(:instrument_id, :institution_id)
    institutions = owner.institutions.where(id: pairs.map(&:last)).index_by(&:id)
    @institutions_by_instrument = pairs.group_by(&:first).transform_values do |instrument_pairs|
      instrument_pairs.filter_map { |_instrument_id, institution_id| institutions[institution_id] }.sort_by(&:name)
    end
    return unless @corporate_action&.institution

    institutions = @institutions_by_instrument[@corporate_action.instrument_id] ||= []
    institutions << @corporate_action.institution unless institutions.include?(@corporate_action.institution)
    institutions.sort_by!(&:name)
  end

  def assign_corporate_action_attributes
    attributes = corporate_action_params
    gross_amount = attributes.delete(:gross_amount)
    withholding_tax = attributes.delete(:withholding_tax)
    @corporate_action.assign_attributes(attributes)
    @corporate_action.instrument = @context_instrument if @context_instrument
    @corporate_action.currency = @corporate_action.instrument&.currency
    @corporate_action.source = "manual"
    assign_cash_amounts(gross_amount:, withholding_tax: withholding_tax.presence || "0")
  end

  def assign_cash_amounts(gross_amount:, withholding_tax:)
    @corporate_action.gross_amount = Money.from_amount(BigDecimal(gross_amount), @corporate_action.currency)
    @corporate_action.withholding_tax = Money.from_amount(
      BigDecimal(withholding_tax), @corporate_action.currency
    )
    @corporate_action.net_amount_cents =
      @corporate_action.gross_amount_cents - @corporate_action.withholding_tax_cents
  rescue ArgumentError, TypeError
    @corporate_action.gross_amount_cents = nil
    @corporate_action.withholding_tax_cents = nil
    @corporate_action.net_amount_cents = nil
  end

  def corporate_action_params
    params.expect(corporate_action: %i[
      instrument_id institution_id kind paid_on ex_date gross_amount withholding_tax notes
    ])
  end

  def enqueue_historical_data_backfill
    CorporateActions::HistoricalDataBackfillEnqueuer.call(corporate_action: @corporate_action)
  end
end
