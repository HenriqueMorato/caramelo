class PositionsController < ApplicationController
  allow_unauthenticated_access

  def index
    @show_closed = params[:closed] == "1"
    @position_results = Position.overview
    @has_closed_positions = @position_results.any? { |result| result.position&.closed? }
    visible_results = @position_results.select do |result|
      result.invalid? || @show_closed || result.position.open?
    end
    market_price_service = MarketPrice::Service.default
    @positions = visible_results.map do |position_result|
      Position::Presenter.for(position_result:, market_price_service:)
    end
    @has_refreshable_market_prices = @positions.any?(&:market_price_refreshable?)
  end
end
