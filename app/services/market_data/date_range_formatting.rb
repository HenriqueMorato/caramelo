module MarketData
  module DateRangeFormatting
    module_function

    def compact_ranges(dates)
      dates.sort.slice_when { |left, right| right != left + 1.day }
        .map { |group| group.first..group.last }.to_a
    end

    def format_ranges(ranges)
      ranges.map do |range|
        range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}"
      end.join(", ")
    end

    def format_dates(dates)
      format_ranges(compact_ranges(dates))
    end
  end
end
