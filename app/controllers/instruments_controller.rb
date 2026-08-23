class InstrumentsController < ApplicationController
  allow_unauthenticated_access

  before_action :set_instrument, only: %i[ show edit update destroy ]

  def index
    @instruments = owner.instruments.alphabetical
  end

  def show
  end

  def new
    @instrument = owner.instruments.new
  end

  def create
    @instrument = owner.instruments.new(instrument_params)

    if @instrument.save
      redirect_to @instrument, notice: "Instrument was created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @instrument.update(instrument_params)
      redirect_to @instrument, notice: "Instrument was updated.", status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    if @instrument.destroy
      redirect_to instruments_path, notice: "Instrument was deleted.", status: :see_other
    else
      redirect_to @instrument, alert: @instrument.errors.full_messages.to_sentence, status: :see_other
    end
  end

  private

  def owner
    @owner ||= User.owner
  end

  def set_instrument
    @instrument = owner.instruments.find(params.expect(:id))
  end

  def instrument_params
    params.expect(instrument: %i[ticker name currency])
  end
end
