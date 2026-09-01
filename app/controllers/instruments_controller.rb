class InstrumentsController < ApplicationController
  allow_unauthenticated_access

  before_action :set_instrument, only: %i[ show edit update destroy ]

  def index
    @instruments = Instrument.alphabetical
  end

  def show
    @trades = User.owner.trades.where(instrument: @instrument).includes(:instrument, :institution).strict_loading.reverse_chronological.load
    @market_price = MarketPrice::Presenter.for(instrument: @instrument)
    @position = Position.for(instrument: @instrument, trades: @trades)
    @valuation = Valuation::Current.for(position: @position, market_price: @market_price)
    @performance_pending = HistoricalDataBackfill.pending_for?(instruments: [ @instrument ])
    @performance = Performance::Portfolio.for(valuation_date: Date.current, instrument: @instrument, trades: @trades)
    @performance_presenter = Performance::Presenter.for(
      performance: @performance, pending: @performance_pending
    )
  rescue Position::InvalidLongOnlyData => error
    @position_error = error
  end

  def new
    @instrument = Instrument.new
  end

  def create
    @instrument = Instrument.new(instrument_params)

    if @instrument.save
      redirect_to @instrument, notice: t("notices.Created", model: Instrument.model_name.human)
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @instrument.update(instrument_params)
      redirect_to @instrument, notice: t("notices.Updated", model: Instrument.model_name.human), status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    if @instrument.destroy
      redirect_to instruments_path, notice: t("notices.Deleted", model: Instrument.model_name.human), status: :see_other
    else
      redirect_to @instrument, alert: @instrument.errors.full_messages.to_sentence, status: :see_other
    end
  end

  private

  def set_instrument
    @instrument = Instrument.find(params.expect(:id))
  end

  def instrument_params
    params.expect(instrument: %i[ticker exchange name currency])
  end
end
