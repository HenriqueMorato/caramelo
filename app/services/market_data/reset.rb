module MarketData
  class Reset
    SUPPORTED_KINDS = Recovery::HANDLERS.keys.freeze

    Result = Data.define(:status, :target) do
      def queued? = status == :queued
      def unsupported? = status == :unsupported
      def busy? = status == :busy
      def throttled? = status == :throttled
      def already_running? = status == :already_running
    end

    def self.call(target:, preview_token: nil, owner: User.owner, cache: Rails.cache)
      new(target:, preview_token:, owner:, cache:).call
    end

    def initialize(target:, preview_token:, owner:, cache:)
      @target = target
      @preview_token = preview_token
      @owner = owner
      @cache = cache
    end

    def call
      return result(:unsupported) unless SUPPORTED_KINDS.include?(target.kind)
      raise ArgumentError, "reset preview is required" if preview_token.blank?

      preview = ResetPreview.verify(token: preview_token, target:, owner:)

      return queue_current_price_reset if target.kind == :current_price

      recovery = Recovery.call(target:, range: preview.range, owner:, cache:)
      result(recovery.status)
    end

    private

    def queue_current_price_reset
      instrument = Instrument.find(target.record_id)
      raise ActiveRecord::RecordNotFound unless owner.trades.exists?(instrument:)
      return result(:busy) if RefreshStatus::State.read(target.scope)&.active?

      lease = RecoveryLease.acquire(target:, cache:)
      return result(:busy) unless lease

      status = nil
      PublicationFence.new(target:, cache:).advance do
        job = MarketPrice::RefreshEnqueuer.new.enqueue(
          instrument:, batch_scope: nil, batch_run_id: nil,
          lease_token: lease.token, lease_target: target.to_h
        )
        status = job ? :queued : :unsupported
        RecoveryLease.release(target:, token: lease.token, cache:) unless job
      end
      result(status)
    rescue StandardError
      RecoveryLease.release(target:, token: lease.token, cache:) if lease
      raise
    end

    attr_reader :target, :preview_token, :owner, :cache

    def result(status)
      Result.new(status:, target:)
    end
  end
end
