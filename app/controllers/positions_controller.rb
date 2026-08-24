class PositionsController < ApplicationController
  allow_unauthenticated_access

  def index
    @show_closed = params[:closed] == "1"
    @position_entries = Position.overview
    @has_closed_positions = @position_entries.any? { |entry| entry.position&.closed? }
    @visible_entries = @position_entries.select do |entry|
      entry.invalid? || @show_closed || entry.position.open?
    end
  end
end
