class ScheduleCorporateActionImportsJob < ApplicationJob
  queue_as :market_prices

  limits_concurrency key: ->(*) { "corporate-action-imports:scheduler" },
    duration: 2.minutes, on_conflict: :block

  def perform
    CorporateActionImports::Automation.call
  end
end
