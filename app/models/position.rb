class Position
  ANALYTICAL_DECIMAL_PRECISION = 48

  CalculationResult = Data.define(:instrument, :position, :error) do
    def invalid?
      error.present?
    end

    def trades
      position&.trades || error&.trades || [ error&.trade ].compact
    end
  end

  # Exact moving-average replay output. `cost_basis_amount` and
  # `realized_gain_amount` use the amount supplied by the caller, so it can be
  # either an instrument's native currency or the reporting currency.
  Calculation = Data.define(:quantity, :cost_basis_amount, :realized_gain_amount)

  class InvalidLongOnlyData < StandardError
    attr_reader :trade, :trades

    def initialize(trade, trades: nil)
      @trade = trade
      @trades = trades || [ trade ]
      super("Trade #{trade.id} would make the position quantity negative")
    end
  end

  class InvalidQuantityActionData < StandardError
    attr_reader :action, :trades

    def initialize(action, trades:, reason:)
      @action = action
      @trades = trades
      super("Corporate action #{action.id || action.slug} #{reason}")
    end
  end

  class Calculator
    def self.for(trades:, amount_for:, corporate_actions: [], cash_in_lieu_amount_for: nil)
      new(trades:, amount_for:, corporate_actions:, cash_in_lieu_amount_for:).calculate
    end

    def self.quantity_timeline(trades:, amount_for:, corporate_actions: [], cash_in_lieu_amount_for: nil)
      new(trades:, amount_for:, corporate_actions:, cash_in_lieu_amount_for:).quantity_timeline
    end

    def initialize(trades:, amount_for:, corporate_actions:, cash_in_lieu_amount_for:)
      @trades = trades
      @amount_for = amount_for
      @corporate_actions = corporate_actions
      @cash_in_lieu_amount_for = cash_in_lieu_amount_for ||
        ->(action) { action.cash_in_lieu_amount&.to_d }
    end

    def calculate
      state = replay

      Calculation.new(
        quantity: state.quantity, cost_basis_amount: state.cost_basis_amount,
        realized_gain_amount: state.realized_gain_amount
      )
    rescue InvalidLongOnlyData => error
      raise InvalidLongOnlyData.new(error.trade, trades:)
    end

    def quantity_timeline
      timeline = {}
      replay { |date, state| timeline[date] = state.quantity }
      timeline
    rescue InvalidLongOnlyData => error
      raise InvalidLongOnlyData.new(error.trade, trades:)
    end

    private

    # Internal values remain Rational to avoid introducing rounding into a
    # partial-sale allocation before the public analytical decimal boundary.
    State = Struct.new(:quantity, :cost_basis_amount, :realized_gain_amount)

    attr_reader :trades, :amount_for, :corporate_actions, :cash_in_lieu_amount_for

    def replay
      state = State.new(0.to_r, 0.to_r, 0.to_r)
      ledger_events.group_by { |event| event_date(event) }.each do |date, events|
        events.each { |event| apply_event(state, event) }
        yield date, state if block_given?
      end
      state
    end

    def apply_event(state, event)
      if event.is_a?(Trade)
        event.buy? ? apply_buy(state, event) : apply_sell(state, event)
      else
        apply_quantity_action(state, event)
      end
    end

    def event_date(event)
      event.is_a?(Trade) ? event.traded_on : event.effective_on
    end

    def ledger_events
      (corporate_actions + trades).each_with_index.sort_by do |event, original_index|
        if event.is_a?(Trade)
          [ event.traded_on, 1, event.id || original_index ]
        else
          [ event.effective_on, 0, event.id || original_index ]
        end
      end.map(&:first)
    end

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

    def apply_quantity_action(state, action)
      return if state.quantity.zero?

      adjusted_quantity = state.quantity * action.quantity_multiplier
      disposed_quantity = action.cash_in_lieu_quantity&.to_r || 0.to_r
      if disposed_quantity > adjusted_quantity
        raise InvalidQuantityActionData.new(action, trades:, reason: "disposes of more than the adjusted quantity")
      end

      if disposed_quantity.positive?
        allocated_cost_basis = state.cost_basis_amount * disposed_quantity / adjusted_quantity
        proceeds = cash_in_lieu_amount_for.call(action)
        if proceeds.nil?
          raise InvalidQuantityActionData.new(action, trades:, reason: "is missing cash-in-lieu proceeds")
        end

        state.realized_gain_amount += proceeds.to_r - allocated_cost_basis
        state.cost_basis_amount -= allocated_cost_basis
      end

      state.quantity = adjusted_quantity - disposed_quantity
    end

    def remaining_cost_basis(cost_basis_amount, remaining_quantity, quantity)
      return 0.to_r if remaining_quantity.zero?

      cost_basis_amount * remaining_quantity / quantity
    end
  end

  attr_reader :instrument, :trades, :corporate_actions, :quantity, :analytical_cost_basis_amount, :cost_basis,
    :average_unit_cost, :analytical_realized_gain_amount, :realized_gain,
    :first_trade_date, :last_trade_date

  def self.for(instrument:, as_of: nil, trades: nil, corporate_actions: nil)
    if trades.nil? && corporate_actions.nil? && as_of.nil?
      materialization = PositionMaterialization.where.not(calculated_at: nil)
        .find_by(user: User.owner, instrument:)
      return from_materialization(materialization) if materialization
    end

    if trades
      trades = trades.select { |trade| trade.user_id == User.owner.id && trade.instrument == instrument }
      trades = trades.select { |trade| trade.traded_on <= as_of } if as_of
      trades.sort_by! { |trade| [ trade.traded_on, trade.id ] }
    else
      trades = User.owner.trades.where(instrument:)
      trades = trades.where(traded_on: ..as_of) if as_of
      trades = trades.order(:traded_on, :id).to_a
    end

    corporate_actions = quantity_actions_for(
      instrument:, as_of:, supplied_actions: corporate_actions
    )
    new(instrument:, trades:, corporate_actions:)
  end

  def self.from_materialization(materialization)
    new(instrument: materialization.instrument, trades: [], corporate_actions: [], calculation: Calculation.new(
      quantity: materialization.quantity,
      cost_basis_amount: materialization.cost_basis_amount,
      realized_gain_amount: materialization.realized_gain_amount
    ))
  end

  def self.overview(owner: User.owner, include_institutions: false)
    return replay_overview(owner:) if !include_institutions && owner.position_materializations.none?
    return materialized_overview(owner:) unless include_institutions

    trades_by_instrument = owner.trades.includes(%i[instrument institution]).strict_loading
      .order(:traded_on, :id).group_by(&:instrument)
    actions_by_instrument = quantity_actions_by_instrument(owner)

    instruments = (trades_by_instrument.keys | actions_by_instrument.keys)
      .sort_by { |instrument| [ instrument.ticker, instrument.exchange ] }
    instruments.map do |instrument|
      trades = trades_by_instrument.fetch(instrument, [])
      position = materialized_position(instrument, owner:) || new(
        instrument:, trades:, corporate_actions: actions_by_instrument.fetch(instrument, [])
      )
      CalculationResult.new(instrument:, position:, error: nil)
    rescue InvalidLongOnlyData, InvalidQuantityActionData => error
      CalculationResult.new(instrument:, position: nil, error:)
    end
  end

  def self.replay_overview(owner:)
    trades_by_instrument = owner.trades.includes(:instrument).strict_loading.order(:traded_on, :id).group_by(&:instrument)
    actions_by_instrument = quantity_actions_by_instrument(owner)

    instruments = (trades_by_instrument.keys | actions_by_instrument.keys)
      .sort_by { |instrument| [ instrument.ticker, instrument.exchange ] }
    instruments.map do |instrument|
      position = new(
        instrument:, trades: trades_by_instrument.fetch(instrument, []),
        corporate_actions: actions_by_instrument.fetch(instrument, [])
      )
      CalculationResult.new(instrument:, position:, error: nil)
    rescue InvalidLongOnlyData, InvalidQuantityActionData => error
      CalculationResult.new(instrument:, position: nil, error:)
    end
  end

  def self.materialized_overview(owner:)
    materializations = owner.position_materializations.index_by(&:instrument_id)
    instrument_ids = owner.trades.distinct.pluck(:instrument_id) |
      owner.corporate_actions.effective.where(effective_on: ..Date.current).distinct.pluck(:instrument_id)
    actions_by_instrument = quantity_actions_by_instrument(owner)
    Instrument.where(id: instrument_ids).alphabetical.map do |instrument|
      materialization = materializations[instrument.id]
      position = materialization&.calculated_at ? from_materialization(materialization) : new(
        instrument:, trades: owner.trades.where(instrument:).order(:traded_on, :id).to_a,
        corporate_actions: actions_by_instrument.fetch(instrument, [])
      )
      CalculationResult.new(instrument:, position:, error: nil)
    rescue InvalidLongOnlyData, InvalidQuantityActionData => error
      CalculationResult.new(instrument:, position: nil, error:)
    end
  end

  def self.materialized_position(instrument, owner:)
    return if owner != User.owner

    materialization = PositionMaterialization.find_by(user: owner, instrument:)
    return unless materialization&.calculated_at

    from_materialization(materialization)
  end

  def self.quantity_actions_for(instrument:, as_of:, supplied_actions:)
    actions = if supplied_actions
      supplied_actions.select do |action|
        action.user_id == User.owner.id && action.instrument == instrument &&
          action.confirmed? && action.quantity_action?
      end
    else
      User.owner.corporate_actions.effective.where(instrument:).where.not(effective_on: nil).to_a
    end
    effective_through = as_of || Date.current
    actions = actions.select { |action| action.effective_on <= effective_through }
    actions.sort_by { |action| [ action.effective_on, action.id || 0 ] }
  end

  def self.quantity_actions_by_instrument(owner)
    owner.corporate_actions.effective.where(effective_on: ..Date.current)
      .includes(:instrument).order(:effective_on, :id).group_by(&:instrument)
  end

  private_class_method :quantity_actions_for, :quantity_actions_by_instrument

  def open?
    quantity.positive?
  end

  def closed?
    quantity.zero?
  end

  private_class_method :new

  def initialize(instrument:, trades:, corporate_actions:, calculation: nil)
    @instrument = instrument
    @trades = trades.freeze
    @corporate_actions = corporate_actions.freeze
    @quantity = BigDecimal("0")
    @first_trade_date = trades.first&.traded_on
    @last_trade_date = trades.last&.traded_on

    calculation ? apply_calculation(calculation) : calculate(trades, corporate_actions)
    freeze
  end

  def calculate(trades, corporate_actions)
    calculation = Calculator.for(
      trades:, corporate_actions:, amount_for: ->(trade) { trade.total_amount }
    )
    @quantity = analytical_decimal(calculation.quantity)
    @analytical_cost_basis_amount = analytical_decimal(calculation.cost_basis_amount)
    @cost_basis = Money.from_amount(analytical_cost_basis_amount, instrument.currency)
    @average_unit_cost = calculate_average_unit_cost(calculation.cost_basis_amount, calculation.quantity)
    @analytical_realized_gain_amount = analytical_decimal(calculation.realized_gain_amount)
    @realized_gain = Money.from_amount(analytical_realized_gain_amount, instrument.currency)
  end

  def apply_calculation(calculation)
    @quantity = calculation.quantity
    @analytical_cost_basis_amount = calculation.cost_basis_amount
    @cost_basis = Money.from_amount(analytical_cost_basis_amount, instrument.currency)
    @average_unit_cost = calculate_average_unit_cost(
      calculation.cost_basis_amount.to_r, calculation.quantity.to_r
    )
    @analytical_realized_gain_amount = calculation.realized_gain_amount
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
