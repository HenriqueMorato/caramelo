require "net/http"

module MarketData
  module Bcb
    class Error < StandardError; end
    class InvalidResponse < Error; end

    class Client
      BASE_URI = URI("https://api.bcb.gov.br/dados/serie/bcdata.sgs")
      SERIES = { "CDI" => 12 }.freeze
      MAX_CHUNK_DAYS = 365

      Observation = Data.define(:observed_on, :value, :observed_at)

      def initialize(http: Net::HTTP, open_timeout: 5, read_timeout: 15)
        @http = http
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def daily_rates(identifier:, from:, to:)
        validate_range!(from, to)
        series = SERIES.fetch(identifier.to_s.strip.upcase) do
          raise ArgumentError, "unsupported BCB series"
        end

        ranges(from, to).flat_map { |range| fetch_range(series, range.begin, range.end) }.uniq(&:observed_on).sort_by(&:observed_on)
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
        raise InvalidResponse, error.message
      end

      private

      attr_reader :http, :open_timeout, :read_timeout

      def validate_range!(from, to)
        return if from.is_a?(Date) && to.is_a?(Date) && from <= to

        raise ArgumentError, "BCB date range must use dates in chronological order"
      end

      def ranges(from, to)
        starts = (from..to).step(MAX_CHUNK_DAYS).to_a
        starts.map { |start| start..[ start + MAX_CHUNK_DAYS - 1, to ].min }
      end

      def fetch_range(series, from, to)
        uri = BASE_URI.dup
        uri.path = "#{uri.path}/#{series}/dados"
        uri.query = URI.encode_www_form(dataInicial: from.strftime("%d/%m/%Y"), dataFinal: to.strftime("%d/%m/%Y"))
        response = request(uri)
        return [] if empty_response?(response)
        raise InvalidResponse, "BCB returned HTTP #{response.code}" unless (200..299).cover?(response.code.to_i)

        parse(response.body, from:, to:)
      end

      def empty_response?(response)
        return false unless response.code.to_i == 404

        body = JSON.parse(response.body)
        body.dig("erro", "detail").to_s.include?("Value(s) not found")
      rescue JSON::ParserError, TypeError
        false
      end

      def request(uri)
        http.start(uri.host, uri.port, use_ssl: true, open_timeout:, read_timeout:) do |connection|
          connection.get(uri.request_uri)
        end
      rescue SocketError, Timeout::Error, IOError => error
        raise Error, error.message
      end

      def parse(body, from:, to:)
        entries = JSON.parse(body)
        raise InvalidResponse, "BCB response must be an array" unless entries.is_a?(Array)

        entries.filter_map do |entry|
          date = Date.strptime(entry.fetch("data"), "%d/%m/%Y")
          next unless (from..to).cover?(date)

          value = BigDecimal(entry.fetch("valor").to_s.tr(",", ".")) / 100
          next unless value.finite? && value >= 0

          Observation.new(observed_on: date, value:, observed_at: date.to_time.utc)
        end.sort_by(&:observed_on)
      end
    end
  end
end
