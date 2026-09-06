module MarketData
  # A short-lived, signed description of the exact data a reset would replace.
  # The fingerprint forces a fresh preview when source rows change meanwhile.
  class ResetPreview
    TTL = 15.minutes

    Preview = Data.define(:target, :range, :fingerprint, :token, :expires_at) do
      def expired?
        expires_at <= Time.current
      end
    end

    def self.create(target:, owner: User.owner, range: nil, verifier: default_verifier)
      from, to = normalized_range(range)
      fingerprint = fingerprint_for(target:, owner:, from:, to:)
      payload = { target: target.to_h, from:, to:, fingerprint:, exp: TTL.from_now.to_i }
      token = verifier.generate(payload)
      Preview.new(target:, range: from..to, fingerprint:, token:, expires_at: Time.at(payload[:exp]))
    end

    def self.verify(token:, target:, owner: User.owner, verifier: default_verifier)
      payload = verifier.verify(token)
      raise ArgumentError, "reset preview expired" if payload.fetch("exp") < Time.current.to_i

      expected_target = canonical_target(target.to_h)
      actual_target = canonical_target(payload.fetch("target").to_h)
      raise ArgumentError, "reset preview target mismatch" unless actual_target == expected_target

      fingerprint = fingerprint_for(
        target:, owner:, from: Date.iso8601(payload.fetch("from")), to: Date.iso8601(payload.fetch("to"))
      )
      raise ArgumentError, "reset preview is stale" unless fingerprint == payload.fetch("fingerprint")

      Preview.new(
        target:, range: Date.iso8601(payload.fetch("from"))..Date.iso8601(payload.fetch("to")),
        fingerprint:, token:, expires_at: Time.at(payload.fetch("exp"))
      )
    rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, ArgumentError => error
      raise ArgumentError, "invalid reset preview: #{error.message}"
    end

    def self.normalized_range(range)
      return [ TradingCalendar.previous_business_day, TradingCalendar.previous_business_day ] unless range
      return [ range.begin, range.end ] if range.is_a?(Range) && range.begin.is_a?(Date) && range.end.is_a?(Date) && range.begin <= range.end

      raise ArgumentError, "reset range must use dates in chronological order"
    end

    def self.fingerprint_for(target:, owner:, from:, to:)
      rows = case target.kind
      when :current_price
        CurrentMarketPriceCache.new.read(instrument: Instrument.find(target.record_id), provider: target.provider).current_market_price
      when :daily_closing_prices
        DailyClosingPrice.where(instrument_id: target.record_id, provider: target.provider,
          trading_date: from..to).order(:id).pluck(:id, :updated_at)
      when :historical_exchange_rates
        historical_rate_rows(target:, from:, to:)
      when :benchmark_observations
        MarketBenchmarkObservation.joins(:market_benchmark).where(
          market_benchmark_id: target.record_id,
          market_benchmarks: { provider: target.provider }, observed_on: from..to
        ).order(:id).pluck(:id, :updated_at)
      when :portfolio_performance
        PortfolioPerformanceObservation.where(user: owner, reporting_currency: owner.reporting_currency, observed_on: from..to).order(:id).pluck(:id, :updated_at)
      else
        []
      end
      Digest::SHA256.hexdigest(rows.to_json)
    end

    def self.historical_rate_rows(target:, from:, to:)
      HistoricalExchangeRate.where(provider: target.provider, rate_date: from..to)
        .where(
          "(base_currency = ? AND quote_currency = ?) OR (base_currency = ? AND quote_currency = ?)",
          target.base_currency, target.quote_currency, target.quote_currency, target.base_currency
        ).order(:id).pluck(:id, :updated_at)
    end

    def self.default_verifier
      Rails.application.message_verifier("market-data-reset-preview")
    end

    def self.canonical_target(target)
      target.to_h.stringify_keys.transform_values { |value| value.is_a?(Symbol) ? value.to_s : value }
    end

    private_class_method :default_verifier, :fingerprint_for, :canonical_target
  end
end
