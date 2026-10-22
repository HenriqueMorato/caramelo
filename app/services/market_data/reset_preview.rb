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

    def self.create(target:, owner: User.default_owner, range: nil, verifier: default_verifier)
      from, to = normalized_range(range)
      fingerprint = fingerprint_for(target:, owner:, from:, to:)
      payload = { target: target.to_h, from:, to:, fingerprint:, exp: TTL.from_now.to_i }
      token = verifier.generate(payload)
      Preview.new(target:, range: from..to, fingerprint:, token:, expires_at: Time.at(payload[:exp]))
    end

    def self.verify(token:, target:, owner: User.default_owner, verifier: default_verifier)
      payload = verifier.verify(token)
      validate_expiry!(payload)
      validate_target!(payload, target)
      fingerprint = validate_fingerprint!(payload, target, owner)
      preview_from(payload, target, fingerprint, token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, ArgumentError => error
      raise ArgumentError, "invalid reset preview: #{error.message}"
    end

    def self.validate_expiry!(payload)
      raise ArgumentError, "reset preview expired" if payload.fetch("exp") < Time.current.to_i
    end

    def self.validate_target!(payload, target)
      expected_target = canonical_target(target.to_h)
      actual_target = canonical_target(payload.fetch("target").to_h)
      return if actual_target == expected_target

      raise ArgumentError, "reset preview target mismatch"
    end

    def self.validate_fingerprint!(payload, target, owner)
      from = Date.iso8601(payload.fetch("from"))
      to = Date.iso8601(payload.fetch("to"))
      fingerprint = fingerprint_for(target:, owner:, from:, to:)
      return fingerprint if fingerprint == payload.fetch("fingerprint")

      raise ArgumentError, "reset preview is stale"
    end

    def self.preview_from(payload, target, fingerprint, token)
      from = Date.iso8601(payload.fetch("from"))
      to = Date.iso8601(payload.fetch("to"))
      Preview.new(target:, range: from..to, fingerprint:, token:, expires_at: Time.at(payload.fetch("exp")))
    end

    def self.normalized_range(range)
      return [ TradingCalendar.previous_business_day, TradingCalendar.previous_business_day ] unless range
      return [ range.begin, range.end ] if range.is_a?(Range) && range.begin.is_a?(Date) && range.end.is_a?(Date) && range.begin <= range.end

      raise ArgumentError, "reset range must use dates in chronological order"
    end

    def self.fingerprint_for(target:, owner:, from:, to:)
      rows = fingerprint_rows(target:, owner:, from:, to:)
      Digest::SHA256.hexdigest(rows.to_json)
    end

    def self.fingerprint_rows(target:, owner:, from:, to:)
      case target.kind
      when :current_price then current_price_rows(target)
      when :current_exchange_rate then current_exchange_rate_rows(target)
      when :daily_closing_prices then daily_closing_price_rows(target:, from:, to:)
      when :historical_exchange_rates then historical_rate_rows(target:, from:, to:)
      when :benchmark_observations then benchmark_rows(target:, from:, to:)
      when :portfolio_performance then portfolio_performance_rows(target:, owner:, from:, to:)
      when :instrument_performance then instrument_performance_rows(target:, owner:, from:, to:)
      else []
      end
    end

    def self.current_price_rows(target)
      CurrentMarketPriceCache.new.read(
        instrument: Instrument.find(target.record_id), provider: target.provider
      ).current_market_price
    end

    def self.current_exchange_rate_rows(target)
      ExchangeRateCache.new.read(
        base_currency: target.base_currency, quote_currency: target.quote_currency, provider: target.provider
      ).exchange_rate
    end

    def self.daily_closing_price_rows(target:, from:, to:)
      DailyClosingPrice.where(
        instrument_id: target.record_id, provider: target.provider, trading_date: from..to
      ).order(:id).pluck(:id, :updated_at)
    end

    def self.benchmark_rows(target:, from:, to:)
      MarketBenchmarkObservation.joins(:market_benchmark).where(
        market_benchmark_id: target.record_id,
        market_benchmarks: { provider: target.provider }, observed_on: from..to
      ).order(:id).pluck(:id, :updated_at)
    end

    def self.portfolio_performance_rows(target:, owner:, from:, to:)
      PortfolioPerformanceObservation.where(
        user: owner, reporting_currency: target.quote_currency || owner.reporting_currency, observed_on: from..to
      ).order(:id).pluck(:id, :updated_at)
    end

    def self.instrument_performance_rows(target:, owner:, from:, to:)
      InstrumentPerformanceObservation.where(
        user: owner, instrument_id: target.record_id,
        reporting_currency: target.quote_currency, observed_on: from..to
      ).order(:id).pluck(:id, :updated_at)
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
      target.to_h.stringify_keys.transform_values do |value|
        value.is_a?(Symbol) || value.is_a?(Integer) ? value.to_s : value
      end
    end

    private_class_method :default_verifier, :fingerprint_for, :fingerprint_rows,
      :current_price_rows, :current_exchange_rate_rows, :daily_closing_price_rows,
      :benchmark_rows, :portfolio_performance_rows, :instrument_performance_rows,
      :validate_expiry!, :validate_target!, :validate_fingerprint!, :preview_from, :canonical_target
  end
end
