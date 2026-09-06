module Backup
  class State
    KEY = "localfolio:backup:state"
    TTL = 30.minutes

    def self.current(cache: Rails.cache, now: Time.current)
      new(cache:, now:, attributes: cache.read(KEY)).normalized
    end

    def self.queued!(cache: Rails.cache, now: Time.current)
      write(:queued, cache:, now:)
    end

    def self.running!(cache: Rails.cache, now: Time.current)
      write(:running, cache:, now:)
    end

    def self.completed!(result, cache: Rails.cache, now: Time.current)
      write(:completed, cache:, now:, metadata: { created_at: result.created_at, completed_at: now.iso8601 })
    end

    def self.failed!(error, cache: Rails.cache, now: Time.current)
      write(:failed, cache:, now:, metadata: { completed_at: now.iso8601, error: error.class.name.demodulize })
    end

    def self.write(status, cache:, now:, metadata: {})
      cache.write(KEY, metadata.merge(status: status.to_s, started_at: now.iso8601), expires_in: TTL)
    end
    private_class_method :write

    def initialize(cache:, now:, attributes:)
      @cache = cache
      @now = now
      @attributes = attributes
    end

    attr_reader :status, :started_at, :completed_at, :error

    def normalized
      @status = status_value
      @started_at = parse_time(@attributes&.fetch(:started_at, nil) || @attributes&.fetch("started_at", nil))
      @completed_at = parse_time(@attributes&.fetch(:completed_at, nil) || @attributes&.fetch("completed_at", nil))
      @error = @attributes&.fetch(:error, nil) || @attributes&.fetch("error", nil)
      @status = "interrupted" if @status == "running" && @started_at && @started_at < @now - TTL
      self
    end

    def queued? = status == "queued"
    def running? = status == "running"
    def completed? = status == "completed"
    def failed? = status == "failed"
    def interrupted? = status == "interrupted"
    def active? = queued? || running?

    private

    def status_value
      @attributes&.fetch(:status, nil) || @attributes&.fetch("status", nil)
    end

    def parse_time(value)
      Time.iso8601(value) if value
    rescue ArgumentError
      nil
    end
  end
end
