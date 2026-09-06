class CreateBackupJob < ApplicationJob
  queue_as :maintenance
  queue_with_priority 100

  def perform
    Backup::State.running!
    result = Backup::Creator.call
    Backup::State.completed!(result)
    result
  rescue StandardError => error
    Backup::State.failed!(error)
    raise
  ensure
    Backup::CreationRequest.release
  end
end
