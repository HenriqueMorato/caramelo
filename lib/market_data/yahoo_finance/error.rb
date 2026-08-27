module MarketData
  module YahooFinance
    class Error < StandardError; end

    class ConfigurationError < Error; end
    class InvalidIdentifier < Error; end
    class UnsupportedExchange < Error; end

    class TransportError < Error; end
    class ExecutableNotFound < TransportError; end
    class RequestTimeout < TransportError; end

    class HTTPError < Error
      attr_reader :status, :headers

      def initialize(status:, headers: {}, message: nil)
        @status = status
        @headers = headers.freeze
        super(message || "Yahoo Finance returned HTTP #{status}")
      end
    end

    class Unauthorized < HTTPError; end
    class SymbolNotFound < HTTPError; end

    class RateLimited < HTTPError
      def retry_after
        headers["retry-after"]
      end
    end

    class ProviderUnavailable < HTTPError; end
    class InvalidResponse < Error; end
  end
end
