module CurrencyPredicates
  extend ActiveSupport::Concern

  included do
    Money::Currency.table.each_key do |code|
      define_method(:"currency_#{code}?") do
        respond_to?(:currency) && currency.to_s.upcase == code.to_s.upcase
      end
    end
  end
end
