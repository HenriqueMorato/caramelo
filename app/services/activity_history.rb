class ActivityHistory
  FILTERS = %w[trades income actions].freeze
  REFERENCE_COLUMNS = %i[record_type record_id].freeze

  attr_reader :activity

  def initialize(trades:, income:, activity: nil)
    @trades = trades
    @income = income
    @activity = activity.presence_in(FILTERS)
  end

  def any?
    return transactions.any? unless activity

    transactions.any? || unselected_transactions_exist?
  end

  def transactions
    @transactions ||= if activity
      selected_scope.reorder(selected_date_column => :desc, created_at: :desc, id: :desc).to_a
    else
      records_by_reference.values_at(*ordered_references).compact
    end
  end

  private

  attr_reader :trades, :income

  def ordered_references
    @ordered_references ||= feed_relation.pluck(*REFERENCE_COLUMNS)
  end

  def feed_relation
    Trade.with(activity_entries: cte_expression)
      .from("activity_entries")
      .order(occurred_on: :desc, created_at: :desc, record_type: :desc, record_id: :desc)
  end

  def cte_expression
    [
      reference_relation(trades, model: Trade, date_column: :traded_on),
      reference_relation(cash_income, model: CorporateAction, date_column: :paid_on),
      reference_relation(quantity_actions, model: CorporateAction, date_column: :effective_on)
    ]
  end

  def reference_relation(scope, model:, date_column:)
    table = model.arel_table
    scope.except(:select, :order, :includes, :preload, :eager_load).select(
      Arel::Nodes.build_quoted(model.name).as("record_type"),
      table[:id].as("record_id"),
      table[date_column].as("occurred_on"),
      table[:created_at]
    )
  end

  def records_by_reference
    @records_by_reference ||= {}.tap do |records|
      load_records(records, scope: trades, model: Trade)
      load_records(records, scope: income, model: CorporateAction)
    end
  end

  def load_records(records, scope:, model:)
    ids = ordered_references.filter_map { |type, id| id if type == model.name }
    scope.where(id: ids).each { |record| records[[ model.name, record.id ]] = record } if ids.any?
  end

  def cash_income
    @cash_income ||= income.cash_actions
  end

  def quantity_actions
    @quantity_actions ||= income.quantity_actions
  end

  def unselected_transactions_exist?
    case activity
    when "trades" then cash_income.exists? || quantity_actions.exists?
    when "income" then trades.exists? || quantity_actions.exists?
    when "actions" then trades.exists? || cash_income.exists?
    end
  end

  def selected_scope
    { "trades" => trades, "income" => cash_income, "actions" => quantity_actions }.fetch(activity)
  end

  def selected_date_column
    { "trades" => :traded_on, "income" => :paid_on, "actions" => :effective_on }.fetch(activity)
  end
end
