module MarketData
  class Reset
    Result = Data.define(:status, :target) do
      def queued? = status == :queued
      def unsupported? = status == :unsupported
      def busy? = status == :busy
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
      return result(:unsupported) unless target.kind == :current_price
      raise ArgumentError, "reset preview is required" if preview_token.blank?

      ResetPreview.verify(token: preview_token, target:, owner:)

      instrument = Instrument.find(target.record_id)
      raise ActiveRecord::RecordNotFound unless owner.trades.exists?(instrument:)
      return result(:busy) if RefreshStatus::State.read(target.scope)&.active?

      status = nil
      PublicationFence.new(target:, cache:).advance do
        job = MarketPrice::RefreshEnqueuer.new.enqueue(instrument:, batch_scope: nil, batch_run_id: nil)
        status = job ? :queued : :unsupported
      end
      result(status)
    end

    private

    attr_reader :target, :preview_token, :owner, :cache

    def result(status)
      Result.new(status:, target:)
    end
  end
end
