class TradeExportsController < ApplicationController
  before_action :require_money_values_visible

  def show
    send_data TradeExport::Csv.call(user: current_account),
      filename: "caramelo-trades-#{Time.zone.today.iso8601}.csv",
      type: "text/csv; charset=utf-8",
      disposition: "attachment"
  end
end
