module Backup
  class Scheduler
    KEY_PREFIX = "caramelo:backup:scheduled:"

    def self.enqueue_if_due(wait: 10.minutes, now: Time.current, creator: Creator, job: CreateBackupJob)
      return false unless creator.due?(configuration: Configuration.default, now: now)

      key = "#{KEY_PREFIX}#{now.in_time_zone.to_date.iso8601}"
      claimed = Rails.cache.write(key, true, expires_in: 1.day, unless_exist: true)
      return false unless claimed

      job.set(wait:).perform_later
      true
    rescue StandardError
      Rails.cache.delete(key) if key
      raise
    end
  end
end
