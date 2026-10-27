module PortfolioAllocation
  class PlanEditor
    Result = Data.define(:success, :errors) do
      def success? = success
    end

    def self.call(plan:, owner:, asset_targets:, instrument_targets:)
      new(plan:, owner:, asset_targets:, instrument_targets:).call
    end

    def initialize(plan:, owner:, asset_targets:, instrument_targets:)
      @plan = plan
      @owner = owner
      @asset_targets = asset_targets.to_h
      @instrument_targets = instrument_targets.to_h
      @errors = []
    end

    def call
      parsed_asset_targets = parse_asset_targets
      parsed_instrument_targets = parse_instrument_targets
      validate_totals(parsed_asset_targets, parsed_instrument_targets)
      return Result.new(false, errors) if errors.any?

      persist(parsed_asset_targets, parsed_instrument_targets)
      Result.new(true, [])
    rescue ActiveRecord::RecordInvalid => error
      Result.new(false, [ error.record.errors.full_messages.to_sentence ])
    end

    private

    attr_reader :plan, :owner, :asset_targets, :instrument_targets, :errors

    def parse_asset_targets
      parsed, blank_keys = asset_targets.each_with_object([ {}, [] ]) do |(key, value), (targets, blanks)|
        if value.blank?
          blanks << key
          next
        end

        percentage = decimal(value, "asset type #{key}")
        next unless percentage
        next if percentage.zero?

        normalized_key = AssetType.normalize_key(key)
        unless AssetType.valid_key?(normalized_key)
          errors << "Asset type #{key} is not registered."
          next
        end
        targets[normalized_key] = percentage
      end
      complete_blank_asset_targets(parsed, blank_keys)
    end

    def parse_instrument_targets
      open_instruments = open_instruments_by_id
      instrument_targets.each_with_object({}) do |(id, value), parsed|
        next if value.blank?

        percentage = decimal(value, "instrument #{id}")
        next unless percentage
        next if percentage.zero?

        instrument = open_instruments[id.to_i]
        unless instrument
          errors << "Instrument #{id} must have an open position before it can be planned."
          next
        end
        parsed[instrument] = percentage
      end
    end

    def validate_totals(asset_target_values, instrument_target_values)
      if asset_target_values.empty?
        errors << "Choose at least one asset type target."
      elsif asset_target_values.values.sum != BigDecimal("100")
        errors << "Asset type targets must total 100%."
      end

      grouped_targets = instrument_target_values.group_by { |instrument, _percentage| instrument.asset_type }

      grouped_targets.each do |asset_type_key, targets|
        unless asset_target_values.key?(asset_type_key)
          errors << "Add an asset type target for #{AssetType.label_for(asset_type_key)}."
          next
        end

        total = targets.sum { |_instrument, percentage| percentage }
        available_count = open_instruments_by_id.values.count { |instrument| instrument.asset_type == asset_type_key }
        next if total <= BigDecimal("100") && targets.length < available_count
        next if total == BigDecimal("100")

        errors << "Instrument targets for #{AssetType.label_for(asset_type_key)} must total 100%."
      end

      asset_target_values.each_key do |asset_type_key|
        next if open_instruments_by_id.values.any? { |instrument| instrument.asset_type == asset_type_key }

        errors << "Choose instruments for #{AssetType.label_for(asset_type_key)}."
      end
    end

    def persist(asset_target_values, instrument_target_values)
      plan.transaction do
        plan.instrument_targets.delete_all
        plan.asset_targets.delete_all
        asset_target_values.each do |asset_type_key, percentage|
          plan.asset_targets.create!(asset_type_key:, target_percentage: percentage)
        end
        instrument_target_values.each do |instrument, percentage|
          plan.instrument_targets.create!(
            instrument:, asset_type_key: instrument.asset_type, target_percentage: percentage
          )
        end
      end
    end

    def open_instruments_by_id
      @open_instruments_by_id ||= Position.overview(owner:).filter_map do |result|
        result.instrument if result.position&.open?
      end.index_by(&:id)
    end

    def complete_blank_asset_targets(parsed, blank_keys)
      return parsed if parsed.empty?

      normalized_blank_keys = blank_keys.filter_map do |key|
        normalized_key = AssetType.normalize_key(key)
        normalized_key if AssetType.valid_key?(normalized_key) && !parsed.key?(normalized_key)
      end.uniq
      remainder = BigDecimal("100") - parsed.values.sum
      return parsed unless remainder.positive? && normalized_blank_keys.any?

      share = remainder.div(normalized_blank_keys.length, 8)
      normalized_blank_keys.each_with_index do |key, index|
        parsed[key] = index == normalized_blank_keys.length - 1 ? remainder - share * index : share
      end
      parsed.reject! { |_key, percentage| percentage.zero? }
      parsed
    end

    def decimal(value, label)
      decimal = BigDecimal(value.to_s.strip)
      if decimal.negative? || decimal > 100
        errors << "The #{label} percentage must be 0 or greater and no more than 100."
        return
      end
      decimal
    rescue ArgumentError
      errors << "The #{label} percentage is not a valid number."
      nil
    end
  end
end
