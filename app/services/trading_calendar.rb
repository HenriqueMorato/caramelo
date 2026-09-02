module TradingCalendar
  module_function

  def previous_business_day(date = Date.current)
    candidate = date - 1.day
    candidate -= 1.day while weekend?(candidate)
    candidate
  end

  def weekdays_between(from, to)
    (from..to).reject { |date| weekend?(date) }
  end

  def weekend?(date)
    date.saturday? || date.sunday?
  end
end
