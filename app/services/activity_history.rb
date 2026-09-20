class ActivityHistory
  FILTERS = %w[trades income].freeze
  REFERENCE_COLUMNS = %i[record_type record_id].freeze

  attr_reader :activity

  def initialize(trades:, income:, activity: nil)
    @trades = trades
    @income = income
    @activity = activity.presence_in(FILTERS)
  end

  def any?
    return transactions.any? unless activity

    transactions.any? || unselected_transactions.exists?
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
      reference_relation(income, model: CorporateAction, date_column: :paid_on)
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

  def unselected_transactions
    activity == "trades" ? income : trades
  end

  def selected_scope
    activity == "trades" ? trades : income
  end

  def selected_date_column
    activity == "trades" ? :traded_on : :paid_on
  end
end
