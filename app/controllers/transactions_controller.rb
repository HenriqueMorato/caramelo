class TransactionsController < ApplicationController
  def index
    @activity = params[:activity].presence_in(ActivityHistory::FILTERS)
    history = ActivityHistory.new(trades:, income:, activity: params[:activity])
    @has_transactions = history.any?
    @transactions = history.transactions
    @reviewable_import_count = owner.corporate_action_imports.reviewable.count
  end

  private

  def owner
    @owner ||= current_account
  end

  def trades
    @trades ||= begin
      scope = owner.trades
      scope = scope.includes(:instrument, :institution).strict_loading unless %w[income actions].include?(@activity)
      scope
    end
  end

  def income
    @income ||= begin
      scope = owner.corporate_actions
      scope = scope.includes(:instrument, :institution).strict_loading unless @activity == "trades"
      scope
    end
  end
end
