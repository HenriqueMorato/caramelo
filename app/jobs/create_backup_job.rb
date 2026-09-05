class CreateBackupJob < ApplicationJob
  queue_as :maintenance
  queue_with_priority 100

  def perform
    Backup::Creator.call
  end
end
