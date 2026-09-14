class MoneyVisibilitiesController < ApplicationController
  allow_unauthenticated_access

  def update
    hidden = params.expect(:hidden)
    raise ActionController::BadRequest, "hidden must be true or false" unless %w[true false].include?(hidden)

    session[:money_values_hidden] = hidden == "true"
    redirect_back fallback_location: root_path, status: :see_other
  end
end
