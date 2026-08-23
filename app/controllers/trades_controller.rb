class TradesController < ApplicationController
  allow_unauthenticated_access

  before_action :set_trade, only: %i[ edit update destroy ]
  before_action :set_context_instrument, only: %i[ new create ]
  before_action :set_form_options, only: %i[ new create edit update ]

  def index
    @trades = owner.trades.includes(:instrument, :institution).reverse_chronological
  end

  def new
    @trade = owner.trades.new(
      instrument: @context_instrument,
      institution: default_institution,
      side: :buy,
      traded_on: Date.current
    )
    @trade.currency = @context_instrument.currency if @context_instrument
  end

  def create
    @trade = owner.trades.new
    assign_trade_attributes

    if @trade.save
      redirect_to transactions_path, notice: "Trade was created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    assign_trade_attributes

    if @trade.save
      redirect_to transactions_path, notice: "Trade was updated.", status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @trade.destroy!
    redirect_to transactions_path, notice: "Trade was deleted.", status: :see_other
  end

  private

  def owner
    @owner ||= User.owner
  end

  def set_trade
    @trade = owner.trades.find(params.expect(:id))
  end

  def set_context_instrument
    @context_instrument = Instrument.find(params[:instrument_id]) if params[:instrument_id]
  end

  def set_form_options
    @instruments = Instrument.alphabetical
    @institutions = owner.institutions.active
    @institutions = @institutions.or(owner.institutions.where(id: @trade.institution_id)) if @trade&.persisted?
    @institutions = @institutions.alphabetical
  end

  def assign_trade_attributes
    attributes = trade_params
    fees = attributes.delete(:fees)
    @trade.assign_attributes(attributes)
    @trade.instrument = @context_instrument if @context_instrument
    @trade.currency = @trade.instrument&.currency
    @trade.institution_id = nil unless institution_available?
    assign_money(:fees, fees.presence || "0")
  end

  def available_institutions
    scope = owner.institutions.active
    previous_institution_id = @trade.attribute_in_database("institution_id")
    @trade.persisted? ? scope.or(owner.institutions.where(id: previous_institution_id)) : scope
  end

  def institution_available?
    @trade.institution_id.blank? || available_institutions.exists?(id: @trade.institution_id)
  end

  def trade_params
    params.expect(trade: %i[instrument_id institution_id side traded_on quantity unit_price fees notes])
  end

  def default_institution
    recent_trade_with_active_institution&.institution
  end

  def recent_trade_with_active_institution
    owner.trades.joins(:institution).merge(Institution.active).includes(:institution).reverse_chronological.first
  end

  def assign_money(attribute, value)
    @trade.public_send(:"#{attribute}=", Money.from_amount(BigDecimal(value), @trade.currency))
  rescue ArgumentError
    @trade.public_send(:"#{attribute}_cents=", nil)
  end
end
