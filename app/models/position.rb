class Position
  ANALYTICAL_DECIMAL_PRECISION = 48

  CalculationResult = Data.define(:instrument, :position, :error) do
    def invalid?
      error.present?
    end
  end

  # Exact moving-average replay output. `cost_basis_amount` and
  # `realized_gain_amount` use the amount supplied by the caller, so it can be
  # either an instrument's native currency or the reporting currency.
  Calculation = Data.define(:quantity, :cost_basis_amount, :realized_gain_amount)

  class InvalidLongOnlyData < StandardError
    attr_reader :trade

    def initialize(trade)
      @trade = trade
      super("Trade #{trade.id} would make the position quantity negative")
    end
  end

  class Calculator
    def self.for(trades:, amount_for:)
      new(trades:, amount_for:).calculate
    end

    def initialize(trades:, amount_for:)
      @trades = trades
      @amount_for = amount_for
    end

    def calculate
      state = State.new(0.to_r, 0.to_r, 0.to_r)

      trades.each do |trade|
        trade.buy? ? apply_buy(state, trade) : apply_sell(state, trade)
      end

      Calculation.new(
        quantity: state.quantity, cost_basis_amount: state.cost_basis_amount,
        realized_gain_amount: state.realized_gain_amount
      )
    end

    private

    # Internal values remain Rational to avoid introducing rounding into a
    # partial-sale allocation before the public analytical decimal boundary.
    State = Struct.new(:quantity, :cost_basis_amount, :realized_gain_amount)

    attr_reader :trades, :amount_for

    def apply_buy(state, trade)
      state.quantity += trade.quantity.to_r
      state.cost_basis_amount += amount_for.call(trade).to_r
    end

    def apply_sell(state, trade)
      remaining_quantity = state.quantity - trade.quantity.to_r
      raise InvalidLongOnlyData, trade if remaining_quantity.negative?

      allocated_cost_basis = state.cost_basis_amount * trade.quantity.to_r / state.quantity
      state.realized_gain_amount += amount_for.call(trade).to_r - allocated_cost_basis
      state.cost_basis_amount = remaining_cost_basis(state.cost_basis_amount, remaining_quantity, state.quantity)
      state.quantity = remaining_quantity
    end

    def remaining_cost_basis(cost_basis_amount, remaining_quantity, quantity)
      return 0.to_r if remaining_quantity.zero?

      cost_basis_amount * remaining_quantity / quantity
    end
  end

  attr_reader :instrument, :quantity, :analytical_cost_basis_amount, :cost_basis,
    :average_unit_cost, :analytical_realized_gain_amount, :realized_gain,
    :first_trade_date, :last_trade_date

  def self.for(instrument:, as_of: nil)
    trades = User.owner.trades.where(instrument:)
    trades = trades.where(traded_on: ..as_of) if as_of
    trades = trades.order(:traded_on, :id).to_a

    new(instrument:, trades:)
  end

  def self.overview(owner: User.owner)
    trades_by_instrument = owner.trades.includes(:instrument).strict_loading.order(:traded_on, :id).group_by(&:instrument)

    trades_by_instrument.sort_by { |instrument,| [ instrument.ticker, instrument.exchange ] }.map do |instrument, trades|
      CalculationResult.new(instrument:, position: new(instrument:, trades:), error: nil)
    rescue InvalidLongOnlyData => error
      CalculationResult.new(instrument:, position: nil, error:)
    end
  end

  def open?
    quantity.positive?
  end

  def closed?
    quantity.zero?
  end

  private_class_method :new

  def initialize(instrument:, trades:)
    @instrument = instrument
    @quantity = BigDecimal("0")
    @first_trade_date = trades.first&.traded_on
    @last_trade_date = trades.last&.traded_on

    calculate(trades)
    freeze
  end

  def calculate(trades)
    calculation = Calculator.for(trades:, amount_for: ->(trade) { trade.total_amount })
    @quantity = analytical_decimal(calculation.quantity)
    @analytical_cost_basis_amount = analytical_decimal(calculation.cost_basis_amount)
    @cost_basis = Money.from_amount(analytical_cost_basis_amount, instrument.currency)
    @average_unit_cost = calculate_average_unit_cost(calculation.cost_basis_amount, calculation.quantity)
    @analytical_realized_gain_amount = analytical_decimal(calculation.realized_gain_amount)
    @realized_gain = Money.from_amount(analytical_realized_gain_amount, instrument.currency)
  end

  def calculate_average_unit_cost(cost_basis_amount, quantity)
    return BigDecimal("0") if quantity.zero?

    analytical_decimal(cost_basis_amount / quantity)
  end

  def analytical_decimal(value)
    BigDecimal(value, ANALYTICAL_DECIMAL_PRECISION)
  end
end
