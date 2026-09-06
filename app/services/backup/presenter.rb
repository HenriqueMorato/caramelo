module Backup
  class Presenter
    STATUS_KEYS = %i[missing ready stale invalid queued running completed failed interrupted].freeze

    attr_reader :catalog, :state

    def initialize(catalog:, state:)
      @catalog = catalog
      @state = state
    end

    def entries = catalog.entries
    def latest = catalog.latest
    def schedule = catalog.schedule
    def retention_policy = catalog.retention_policy

    def status
      return state.status.to_sym if state.active? || state.interrupted? || state.failed?

      catalog.status
    end

    def status_key
      STATUS_KEYS.include?(status) ? status : :invalid
    end

    def ready? = status == :ready
    def active? = state.active?
    def latest_verified? = latest&.ready? || false
  end
end
