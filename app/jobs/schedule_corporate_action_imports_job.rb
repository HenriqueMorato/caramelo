class ScheduleCorporateActionImportsJob < ApplicationJob
  queue_as :market_prices

  limits_concurrency key: ->(*) { "corporate-action-imports:scheduler" },
    duration: 2.minutes, on_conflict: :block

  def perform
    users.each { |user| CorporateActionImports::Automation.call(user:) }
  end

  private

  def users
    return [ User.default_owner ] unless Caramelo::AccountMode.multi?

    User.all.to_a
  end
end
