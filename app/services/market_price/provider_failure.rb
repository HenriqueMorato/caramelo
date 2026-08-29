module MarketPrice
  class ProviderFailure < Error
    attr_reader :provider_identifier

    def initialize(provider_identifier:, message:, cause: nil)
      @provider_identifier = provider_identifier
      @cause = cause
      super(message)
    end

    attr_reader :cause

    def retryable?
      cause.is_a?(MarketData::YahooFinance::RateLimited) ||
        cause.is_a?(MarketData::YahooFinance::ProviderUnavailable)
    end

    def retry_after
      cause.retry_after if cause.respond_to?(:retry_after)
    end
  end
end
