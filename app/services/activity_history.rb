class ActivityHistory
  FILTERS = %w[trades income].freeze

  attr_reader :activity

  def initialize(trades:, income:, activity: nil)
    @trades = trades
    @income = income
    @activity = activity.presence_in(FILTERS)
  end

  def any?
    trades.any? || income.any?
  end

  def transactions
    selected_transactions.sort_by do |transaction|
      [ transaction_date(transaction), transaction.created_at, transaction.class.name, transaction.id ]
    end.reverse
  end

  private

  attr_reader :trades, :income

  def selected_transactions
    case activity
    when "trades" then trades.to_a
    when "income" then income.to_a
    else trades.to_a + income.to_a
    end
  end

  def transaction_date(transaction)
    transaction.is_a?(Trade) ? transaction.traded_on : transaction.paid_on
  end
end
