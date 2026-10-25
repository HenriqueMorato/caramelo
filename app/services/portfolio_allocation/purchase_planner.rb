module PortfolioAllocation
  class PurchasePlanner
    Candidate = Data.define(:holding, :target_gap)

    def self.for(candidates:, budget:, count:)
      new(candidates:, budget:, count:).call
    end

    def initialize(candidates:, budget:, count:)
      @candidates = candidates
      @budget = budget
      @count = count
    end

    def call
      selected = select_candidates
      return {} if selected.empty?

      quantities = seed_quantities(selected)
      remaining = @budget - spent_amount(selected, quantities)
      remaining = fill_target_gaps(selected, quantities, remaining)
      fill_remaining(selected, quantities, remaining)

      quantities.to_h do |instrument_id, quantity|
        candidate = selected.find { |item| instrument_id(item) == instrument_id }
        [ instrument_id, price(candidate) * quantity ]
      end
    end

    private

    def select_candidates
      remaining = @budget

      ranked_candidates.each_with_object([]) do |candidate, selected|
        break selected if selected.length >= @count

        cost = step_cost(candidate)
        next if cost > remaining

        selected << candidate
        remaining -= cost
      end
    end

    def ranked_candidates
      @candidates.sort_by do |candidate|
        [ -candidate.target_gap, step_cost(candidate), instrument_id(candidate) ]
      end
    end

    def seed_quantities(selected)
      total_gap = selected.sum(&:target_gap)
      quantities = selected.to_h do |candidate|
        [ instrument_id(candidate), quantity_step(candidate) ]
      end
      remaining = @budget - selected.sum { |candidate| step_cost(candidate) }

      selected.sort_by { |candidate| -candidate.target_gap }.each do |candidate|
        target_amount = @budget * candidate.target_gap / total_gap
        target_steps = (floor_to_step(target_amount / price(candidate), quantity_step(candidate)) / quantity_step(candidate)).to_i
        desired_extra_steps = [ target_steps - 1, 0 ].max
        affordable_steps = [ (remaining / step_cost(candidate)).floor, desired_extra_steps ].min
        next unless affordable_steps.positive?

        quantities[instrument_id(candidate)] += quantity_step(candidate) * affordable_steps
        remaining -= step_cost(candidate) * affordable_steps
      end

      quantities
    end

    def fill_target_gaps(selected, quantities, remaining)
      selected.sort_by { |candidate| -remaining_gap(candidate, quantities) }.each do |candidate|
        break unless remaining.positive?

        gap = remaining_gap(candidate, quantities)
        next unless gap.positive?

        cost = step_cost(candidate)
        steps_needed = (gap / cost).ceil
        affordable_steps = (remaining / cost).floor
        steps = [ steps_needed, affordable_steps ].min
        next unless steps.positive?

        quantities[instrument_id(candidate)] += quantity_step(candidate) * steps
        remaining -= cost * steps
      end

      remaining
    end

    def fill_remaining(selected, quantities, remaining)
      return if remaining <= 0

      candidate = selected.min_by { |item| [ step_cost(item), -remaining_gap(item, quantities) ] }
      steps = (remaining / step_cost(candidate)).floor
      quantities[instrument_id(candidate)] += quantity_step(candidate) * steps if steps.positive?
    end

    def spent_amount(selected, quantities)
      selected.sum { |candidate| price(candidate) * quantities.fetch(instrument_id(candidate)) }
    end

    def remaining_gap(candidate, quantities)
      candidate.target_gap - price(candidate) * quantities.fetch(instrument_id(candidate))
    end

    def price(candidate)
      candidate.holding.price_amount
    end

    def quantity_step(candidate)
      candidate.holding.instrument.quantity_step.to_d
    end

    def step_cost(candidate)
      price(candidate) * quantity_step(candidate)
    end

    def instrument_id(candidate)
      candidate.holding.instrument.id
    end

    def floor_to_step(value, step)
      return BigDecimal("0") unless value.positive?

      (value / step).floor * step
    end
  end
end
