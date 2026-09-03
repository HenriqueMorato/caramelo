module RefreshStatus
  class Presenter
    def self.for
      latest_successful_refresh = State.latest_successful
      new(
        active_refresh: State.active.max_by { |state| [ state.total_count ? 1 : 0, state.started_at || Time.at(0) ] },
        last_successful_refresh_at: latest_successful_refresh&.finished_at,
        latest_successful_refresh:,
        latest_failed_refresh: State.latest_failed
      )
    end

    def initialize(active_refresh:, last_successful_refresh_at:, latest_failed_refresh:, latest_successful_refresh: nil)
      @active_refresh = active_refresh
      @last_successful_refresh_at = last_successful_refresh_at
      @latest_successful_refresh = latest_successful_refresh
      @latest_failed_refresh = latest_failed_refresh
    end

    attr_reader :active_refresh, :last_successful_refresh_at, :latest_failed_refresh, :latest_successful_refresh

    def updating?
      active_refresh.present?
    end

    def current_prices_updating?
      active_refresh&.scope == RefreshStatus::MARKET_PRICE_SCOPE
    end

    def progress_label
      active_refresh&.progress_label
    end

    def failed?
      latest_failed_refresh.present? &&
        latest_failed_refresh.finished_at > (last_successful_refresh_at || Time.at(0))
    end

    def completed_refresh?
      latest_successful_refresh&.scope == RefreshStatus::MARKET_PRICE_SCOPE && !updating?
    end
  end
end
