class InstrumentsController < ApplicationController
  allow_unauthenticated_access

  before_action :set_instrument, only: %i[ show edit update destroy ]

  def index
    @instruments = Instrument.alphabetical
    @traded_instrument_ids = Trade.where(instrument_id: @instruments).distinct.pluck(:instrument_id)
  end

  def show
    @trades = User.owner.trades.where(instrument: @instrument).includes(:instrument, :institution).strict_loading.reverse_chronological.load
    @corporate_actions = owner.corporate_actions.where(instrument: @instrument)
      .includes(:instrument, :institution).strict_loading.reverse_chronological.load
    @instrument_has_activity = @instrument.trades.exists? || @instrument.corporate_actions.exists?
    @reporting_currency = owner.reporting_currency
    @currency_view = requested_currency_view
    @history_mode = params[:history].presence_in(%w[performance price]) || "performance"
    @period_selection = Performance::PeriodSelection.for(
      period: params[:period], owner:, instrument: @instrument
    )
    @selected_period = @period_selection.period
    @market_price = MarketPrice::Presenter.for(instrument: @instrument)
    @header_presenter = Instrument::HeaderPresenter.for(instrument: @instrument, market_price: @market_price)
    @performance_pending = HistoricalDataBackfill.pending_for?(instruments: [ @instrument ])
    @price_history_presenter = price_history_presenter if @history_mode == "price"
    load_position
    @history_performance_views = history_performance_views if @history_mode == "performance" && !@position_error
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

  def price_history_presenter
    DailyClosingPrice::SeriesPresenter.for(
      instrument: @instrument, from: @period_selection.from, to: @period_selection.to
    )
  end

  def load_position
    @position = Position.for(instrument: @instrument, trades: @trades)
    @valuation = Valuation::Current.for(position: @position, market_price: @market_price)
    @performance_presenters = performance_presenters
  rescue Position::InvalidLongOnlyData => error
    @position_error = error
  end

  def history_performance_views
    return {} if @trades.empty?

    performance_currencies.to_h do |name, currency|
      series = Performance::Series.for(
        from: @period_selection.from, to: @period_selection.to,
        user: owner, instrument: @instrument, reporting_currency: currency
      )
      [ name, { currency:, series:, presenter: Performance::SeriesPresenter.new(series) } ]
    end
  end

  def performance_currencies
    currencies = { native: @instrument.currency }
    currencies[:reporting] = @reporting_currency if @instrument.currency != @reporting_currency
    currencies
  end

  def performance_presenters
    presenters = { native: performance_presenter(@instrument.currency) }
    if @instrument.currency != @reporting_currency
      presenters[:reporting] = performance_presenter(@reporting_currency)
    end
    presenters
  end

  def performance_presenter(currency)
    performance = Performance::Portfolio.for(
      valuation_date: Date.current, instrument: @instrument, trades: @trades,
      corporate_actions: @corporate_actions,
      reporting_currency: currency
    )
    Performance::Presenter.for(performance:, pending: @performance_pending)
  end

  def requested_currency_view
    return :reporting if params[:currency_view] == "reporting" && @instrument.currency != @reporting_currency

    :native
  end

  def owner
    @owner ||= User.owner
  end

  def set_instrument
    @instrument = Instrument.friendly.find(params.expect(:id))
  end

  def instrument_params
    params.expect(instrument: %i[ticker exchange name currency asset_type])
  end
end
