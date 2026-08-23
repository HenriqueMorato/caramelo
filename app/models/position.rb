class Position
  class InvalidLongOnlyData < StandardError
    attr_reader :trade

    def initialize(trade)
      @trade = trade
      super("Trade #{trade.id} would make the position quantity negative")
    end
  end

  attr_reader :instrument, :quantity, :cost_basis, :average_unit_cost,
    :first_trade_date, :last_trade_date

  def self.for(instrument:)
    trades = User.owner.trades.where(instrument:).order(:traded_on, :id).to_a

    new(instrument:, trades:)
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
    cost_basis_amount = BigDecimal("0")

    trades.each do |trade|
      if trade.buy?
        @quantity += trade.quantity
        cost_basis_amount += trade.unit_price * trade.quantity + trade.fees.to_d
      else
        remaining_quantity = @quantity - trade.quantity
        raise InvalidLongOnlyData, trade if remaining_quantity.negative?

        cost_basis_amount = remaining_cost_basis(cost_basis_amount, remaining_quantity)
        @quantity = remaining_quantity
      end
    end

    @cost_basis = Money.from_amount(cost_basis_amount, instrument.currency)
    @average_unit_cost = calculate_average_unit_cost(cost_basis_amount)
  end

  def remaining_cost_basis(cost_basis_amount, remaining_quantity)
    return BigDecimal("0") if remaining_quantity.zero?

    cost_basis_amount * remaining_quantity / quantity
  end

  def calculate_average_unit_cost(cost_basis_amount)
    return BigDecimal("0") if quantity.zero?

    cost_basis_amount / quantity
  end
end
