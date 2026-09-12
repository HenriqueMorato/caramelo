module Backup
  class CreationRequest
    CLAIM_KEY = "caramelo:backup:manual-creation"
    CLAIM_TTL = 15.minutes

    def self.call(cache: Rails.cache, creator: Creator, job: CreateBackupJob, state: State)
      return :not_due unless creator.due?
      return :already_queued unless cache.write(CLAIM_KEY, true, expires_in: CLAIM_TTL, unless_exist: true)

      state.queued!
      job.perform_later
      :queued
    rescue StandardError => error
      cache.delete(CLAIM_KEY)
      state.failed!(error)
      raise Backup::Error, "backup could not be queued", cause: error
    end

    def self.release(cache: Rails.cache)
      cache.delete(CLAIM_KEY)
    end
  end
end
