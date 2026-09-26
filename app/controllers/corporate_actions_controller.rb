class CorporateActionsController < ApplicationController
  allow_unauthenticated_access

  before_action :set_corporate_action, only: %i[ edit update edit_quantity update_quantity destroy ]
  before_action :set_return_to, only: %i[ edit update edit_quantity update_quantity destroy ]
  before_action :set_context_instrument, only: %i[ new create new_quantity create_quantity ]
  before_action :set_form_options,
    only: %i[ new create edit update new_quantity create_quantity edit_quantity update_quantity ]
  before_action :require_money_values_visible,
    only: %i[ new create edit update ]
  before_action :require_quantity_action_money_visible,
    only: %i[ create_quantity edit_quantity update_quantity ]

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

  def new_quantity
    @corporate_action = owner.corporate_actions.new(
      instrument: @context_instrument,
      kind: :stock_split,
      status: :confirmed,
      effective_on: Date.current,
      ratio_numerator: 2,
      ratio_denominator: 1,
      source: "manual"
    )
  end

  def create_quantity
    @corporate_action = owner.corporate_actions.new
    assign_quantity_action_attributes

    if @corporate_action.save
      enqueue_historical_data_backfill
      redirect_to transactions_path, notice: t("notices.Created", model: CorporateAction.model_name.human)
    else
      render :new_quantity, status: :unprocessable_content
    end
  end

  def edit
    raise ActiveRecord::RecordNotFound unless @corporate_action.cash_action?
  end

  def edit_quantity
    raise ActiveRecord::RecordNotFound unless @corporate_action.quantity_action?
  end

  def update
    raise ActiveRecord::RecordNotFound unless @corporate_action.cash_action?

    assign_corporate_action_attributes

    if @corporate_action.save
      enqueue_historical_data_backfill
      redirect_to @return_to,
        notice: t("notices.Updated", model: CorporateAction.model_name.human), status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def update_quantity
    raise ActiveRecord::RecordNotFound unless @corporate_action.quantity_action?

    assign_quantity_action_attributes
    if @corporate_action.save
      enqueue_historical_data_backfill
      redirect_to @return_to,
        notice: t("notices.Updated", model: CorporateAction.model_name.human), status: :see_other
    else
      render :edit_quantity, status: :unprocessable_content
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
    @corporate_action.source = "manual" if @corporate_action.new_record?
    assign_cash_amounts(gross_amount:, withholding_tax: withholding_tax.presence || "0")
  end

  def assign_quantity_action_attributes
    attributes = quantity_action_params
    cash_in_lieu_amount = attributes.delete(:cash_in_lieu_amount)
    bonus_percentage = attributes.delete(:bonus_percentage)
    previous_bonus_percentage = @corporate_action.bonus_percentage if @corporate_action.share_bonus?
    if attributes[:kind] == "share_bonus"
      attributes.delete(:ratio_numerator)
      attributes.delete(:ratio_denominator)
    end
    @corporate_action.assign_attributes(attributes)
    if @corporate_action.share_bonus? && bonus_percentage_changed?(bonus_percentage, previous_bonus_percentage)
      @corporate_action.bonus_percentage = bonus_percentage
    end
    @corporate_action.instrument = @context_instrument if @context_instrument
    @corporate_action.source = "manual" if @corporate_action.new_record?
    assign_cash_in_lieu_amount(cash_in_lieu_amount)
  end

  def bonus_percentage_changed?(submitted, previous)
    return true if previous.nil?

    BigDecimal(submitted) != BigDecimal(previous)
  rescue ArgumentError, TypeError
    true
  end

  def assign_cash_in_lieu_amount(amount)
    @corporate_action.cash_in_lieu_amount_input = amount
    if amount.present?
      decimal = BigDecimal(amount)
      raise ArgumentError unless decimal.finite?

      @corporate_action.currency = @corporate_action.instrument&.currency
      @corporate_action.cash_in_lieu_amount = Money.from_amount(
        decimal, @corporate_action.currency
      )
    else
      @corporate_action.cash_in_lieu_amount_cents = nil
      @corporate_action.currency = nil
    end
  rescue ArgumentError, TypeError
    @corporate_action.cash_in_lieu_amount_cents = nil
    @corporate_action.currency = @corporate_action.instrument&.currency
  end

  def require_quantity_action_money_visible
    return unless money_values_hidden?
    return unless @corporate_action&.cash_in_lieu? || submitted_cash_in_lieu_amount?

    redirect_to root_path, alert: t("privacy.Show values before editing"), status: :see_other
  end

  def submitted_cash_in_lieu_amount?
    params.dig(:corporate_action, :cash_in_lieu_amount).present?
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

  def quantity_action_params
    params.expect(corporate_action: %i[
      instrument_id institution_id kind effective_on ratio_numerator ratio_denominator
      bonus_percentage cash_in_lieu_quantity cash_in_lieu_amount notes
    ])
  end

  def enqueue_historical_data_backfill
    CorporateActions::HistoricalDataBackfillEnqueuer.call(corporate_action: @corporate_action)
  end
end
