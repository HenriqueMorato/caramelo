module CorporateActionImports
  class Automation
    SOURCE = Providers::YAHOO_FINANCE
    Result = Data.define(:scheduled_count, :skipped_count, :failed_count) do
      def scheduled? = scheduled_count.positive?
      def failed? = failed_count.positive?
    end

    def self.call(user: User.owner, instrument: nil, source: SOURCE, today: Date.current)
      new(user:, instrument:, source:, today:).call
    end

    def initialize(user:, instrument:, source:, today:)
      @user = user
      @instrument = instrument
      @source = source.to_s.strip.downcase
      @today = today
      raise ArgumentError, "unsupported import source" unless Providers::SUPPORTED_SOURCES.include?(@source)
    end

    def call
      counts = { scheduled: 0, skipped: 0, failed: 0 }
      instruments_with_first_trade.each do |current_instrument, first_trade_on|
        outcome = schedule_for(current_instrument, first_trade_on)
        counts[outcome] += 1
      end
      Result.new(
        scheduled_count: counts[:scheduled],
        skipped_count: counts[:skipped],
        failed_count: counts[:failed]
      )
    end

    private

    attr_reader :user, :instrument, :source, :today

    def instruments_with_first_trade
      relation = user.trades.where(traded_on: ..today)
      relation = relation.where(instrument:) if instrument
      first_dates = relation.group(:instrument_id).minimum(:traded_on)
      Instrument.where(id: first_dates.keys).index_with do |current_instrument|
        first_dates.fetch(current_instrument.id)
      end
    end

    def schedule_for(current_instrument, first_trade_on)
      state = CorporateActionImportScan.for(user:, instrument: current_instrument, source:)
      from = scan_start_for(state, first_trade_on)
      return :skipped if from > today

      request = state.claim!(from:, to: today)
      return :skipped unless request

      scope = CorporateActionImports::ScanStatus.scope(
        user:, from: request.from, to: request.to, source:, instrument_id: current_instrument.id
      )
      status = state.with_current_run(request.run_id) do
        CorporateActionImports::ScanStatus.enqueue(scope:, run_id: request.run_id)
      end
      return :skipped unless status
      job = ScanCorporateActionImportsJob.perform_later(
        user_id: user.id,
        from: request.from.iso8601,
        to: request.to.iso8601,
        source:,
        instrument_id: current_instrument.id,
        scope:,
        scan_run_id: request.run_id,
        automation_scan_id: state.id,
        automation_run_id: request.run_id
      )
      raise ActiveJob::EnqueueError, "corporate action scan could not be enqueued" if enqueue_failed?(job)

      :scheduled
    rescue StandardError => error
      if request
        state.fail!(request.run_id, error:)
        CorporateActionImports::ScanStatus.fail(scope:, run_id: request.run_id, error:) if scope
      end
      Rails.error.report(
        error,
        handled: true,
        context: { user_id: user.id, instrument_id: current_instrument.id, source: }
      )
      :failed
    end

    def scan_start_for(state, first_trade_on)
      return first_trade_on unless state.scanned_through

      [ state.scanned_through, first_trade_on ].max
    end

    def enqueue_failed?(job)
      job.nil? || (job.respond_to?(:successfully_enqueued?) && !job.successfully_enqueued?)
    end
  end
end
