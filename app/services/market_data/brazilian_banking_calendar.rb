module MarketData
  module BrazilianBankingCalendar
    FIXED_HOLIDAYS = [
      [ 1, 1 ], [ 4, 21 ], [ 5, 1 ], [ 9, 7 ], [ 10, 12 ], [ 11, 2 ], [ 11, 15 ], [ 11, 20 ], [ 12, 25 ]
    ].freeze

    module_function

    def business_days_between(from, to)
      (from..to).select { |date| business_day?(date) }
    end

    def business_day?(date)
      !TradingCalendar.weekend?(date) && !holiday?(date)
    end

    def previous_business_day(date)
      candidate = date - 1.day
      candidate -= 1.day until business_day?(candidate)
      candidate
    end

    def holiday?(date)
      FIXED_HOLIDAYS.include?([ date.month, date.day ]) || movable_holidays(date.year).include?(date)
    end

    def movable_holidays(year)
      easter = easter_sunday(year)
      [ easter - 48.days, easter - 47.days, easter - 2.days, easter + 60.days ]
    end

    def easter_sunday(year)
      month, day_offset = easter_month_and_day(year)
      Date.new(year, month, day_offset + 1)
    end

    def easter_month_and_day(year)
      h = easter_epact(year)
      l = easter_weekday_offset(year, h)
      m = (year % 19 + 11 * h + 22 * l) / 451
      (h + l - 7 * m + 114).divmod(31)
    end

    def easter_epact(year)
      a = year % 19
      b = year / 100
      d = b / 4
      f = (b + 8) / 25
      g = (b - f + 1) / 3
      (19 * a + b - d - g + 15) % 30
    end

    def easter_weekday_offset(year, epact)
      century, year_remainder = year.divmod(100)
      century_remainder = century % 4
      year_quarter = year_remainder / 4
      year_remainder_modulo = year_remainder % 4
      (32 + 2 * century_remainder + 2 * year_quarter - epact - year_remainder_modulo) % 7
    end
  end
end
