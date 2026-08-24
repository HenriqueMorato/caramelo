class Position
  ANALYTICAL_DECIMAL_PRECISION = 48

  OverviewEntry = Data.define(:instrument, :position, :error) do
    def invalid?
      error.present?
    end
  end

  class InvalidLongOnlyData < StandardError
    attr_reader :trade

    def initialize(trade)
      @trade = trade
      super("Trade #{trade.id} would make the position quantity negative")
    end
  end

  attr_reader :instrument, :quantity, :analytical_cost_basis_amount, :cost_basis,
    :average_unit_cost, :first_trade_date, :last_trade_date

  def self.for(instrument:)
    trades = User.owner.trades.where(instrument:).order(:traded_on, :id).to_a

    new(instrument:, trades:)
  end

  def self.overview
    trades_by_instrument = User.owner.trades.includes(:instrument).order(:traded_on, :id).group_by(&:instrument)

    trades_by_instrument.sort_by { |instrument,| [ instrument.ticker, instrument.exchange ] }.map do |instrument, trades|
      OverviewEntry.new(instrument:, position: new(instrument:, trades:), error: nil)
    rescue InvalidLongOnlyData => error
      OverviewEntry.new(instrument:, position: nil, error:)
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
    cost_basis_ratio = 0.to_r

    trades.each do |trade|
      if trade.buy?
        @quantity += trade.quantity
        cost_basis_ratio += trade.total_amount.to_r
      else
        remaining_quantity = @quantity - trade.quantity
        raise InvalidLongOnlyData, trade if remaining_quantity.negative?

        cost_basis_ratio = remaining_cost_basis(cost_basis_ratio, remaining_quantity)
        @quantity = remaining_quantity
      end
    end

    @analytical_cost_basis_amount = analytical_decimal(cost_basis_ratio)
    @cost_basis = Money.from_amount(analytical_cost_basis_amount, instrument.currency)
    @average_unit_cost = calculate_average_unit_cost(cost_basis_ratio)
  end

  def remaining_cost_basis(cost_basis_ratio, remaining_quantity)
    return 0.to_r if remaining_quantity.zero?

    cost_basis_ratio * remaining_quantity.to_r / quantity.to_r
  end

  def calculate_average_unit_cost(cost_basis_ratio)
    return BigDecimal("0") if quantity.zero?

    analytical_decimal(cost_basis_ratio / quantity.to_r)
  end

  def analytical_decimal(value)
    BigDecimal(value, ANALYTICAL_DECIMAL_PRECISION)
  end
end
