module MarketPrice
  class ProviderFailure < Error
    attr_reader :provider_identifier

    def initialize(provider_identifier:, message:)
      @provider_identifier = provider_identifier
      super(message)
    end
  end
end
