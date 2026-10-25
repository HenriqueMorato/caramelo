module InvestmentGoals
  class Evaluator
    def self.call(goal:, progress:)
      return goal unless goal.active? && progress.available? && progress.achieved?

      goal.with_lock do
        goal.reload
        current_amount = progress.current_amount
        same_currency = progress.current_value.currency.iso_code == goal.reporting_currency
        if goal.active? && same_currency && current_amount >= goal.target_amount
          goal.update!(status: :achieved, achieved_at: Time.current)
        end
      end
      goal
    end
  end
end
