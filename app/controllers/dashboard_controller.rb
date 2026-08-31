class DashboardController < ApplicationController
  allow_unauthenticated_access

  def index
    @dashboard = Dashboard::Presenter.for
  end
end
