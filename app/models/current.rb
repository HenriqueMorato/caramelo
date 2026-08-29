class Current < ActiveSupport::CurrentAttributes
  attribute :session, :market_price_service, :exchange_rate_service
  delegate :user, to: :session, allow_nil: true
end
