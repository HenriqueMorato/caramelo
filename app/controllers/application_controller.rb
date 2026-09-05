class ApplicationController < ActionController::Base
  include Authentication
  before_action :schedule_daily_backup
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  def schedule_daily_backup
    Backup::Scheduler.enqueue_if_due
  end
end
