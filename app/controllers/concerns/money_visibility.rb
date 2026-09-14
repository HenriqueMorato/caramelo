module MoneyVisibility
  extend ActiveSupport::Concern

  included do
    helper_method :money_values_hidden?
  end

  private

  def money_values_hidden?
    session[:money_values_hidden] == true
  end

  def require_money_values_visible
    return unless money_values_hidden?

    redirect_to root_path, alert: t("privacy.Show values before editing"), status: :see_other
  end
end
