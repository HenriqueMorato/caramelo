module RefreshStatus
  class Presenter
    def self.for(report: nil)
      State.prune!
      latest_successful_refresh = State.latest_successful
      active_refreshes = State.active
      reported_active_count = report ? report.entries.count(&:updating?) : 0
      new(
        active_refresh: active_refreshes.max_by { |state| [ state.total_count ? 1 : 0, state.started_at || Time.at(0) ] },
        active_count: [ active_refreshes.size, reported_active_count ].max,
        last_successful_refresh_at: latest_successful_refresh&.finished_at,
        latest_successful_refresh:,
        latest_failed_refresh: State.latest_failed
      )
    end

    def initialize(active_refresh:, last_successful_refresh_at:, latest_failed_refresh:, latest_successful_refresh: nil,
      active_count: nil)
      @active_refresh = active_refresh
      @active_count = active_count || (active_refresh ? 1 : 0)
      @last_successful_refresh_at = last_successful_refresh_at
      @latest_successful_refresh = latest_successful_refresh
      @latest_failed_refresh = latest_failed_refresh
    end

    attr_reader :active_refresh, :active_count, :last_successful_refresh_at, :latest_failed_refresh,
      :latest_successful_refresh

    def updating?
      active_count.positive?
    end

    def current_prices_updating?
      active_refresh&.scope == RefreshStatus::MARKET_PRICE_SCOPE
    end

    def progress_label
      return "#{active_count} active" if active_count > 1

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
