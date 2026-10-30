module PortfolioAllocation
  class PlanEditor
    GroupDefinition = Data.define(:name, :asset_type_key, :target_percentage, :members)
    MemberDefinition = Data.define(:instrument, :purchase_policy)

    Result = Data.define(:success, :errors) do
      def success? = success
    end

    def self.call(plan:, owner:, asset_targets:, instrument_targets:, groups: {})
      new(plan:, owner:, asset_targets:, instrument_targets:, groups:).call
    end

    def initialize(plan:, owner:, asset_targets:, instrument_targets:, groups:)
      @plan = plan
      @owner = owner
      @asset_targets = asset_targets.respond_to?(:to_h) ? asset_targets.to_h : {}
      @instrument_targets = instrument_targets.respond_to?(:to_h) ? instrument_targets.to_h : {}
      @groups = groups.respond_to?(:to_h) ? groups.to_h : {}
      @errors = []
    end

    def call
      parsed_asset_targets = parse_asset_targets
      parsed_instrument_targets = parse_instrument_targets
      parsed_groups = parse_groups
      validate_totals(parsed_asset_targets, parsed_instrument_targets, parsed_groups)
      return Result.new(false, errors) if errors.any?

      persist(parsed_asset_targets, parsed_instrument_targets, parsed_groups)
      Result.new(true, [])
    rescue ActiveRecord::RecordInvalid => error
      Result.new(false, [ error.record.errors.full_messages.to_sentence ])
    end

    private

    attr_reader :plan, :owner, :asset_targets, :instrument_targets, :groups, :errors

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

    def parse_groups
      groups.each_with_object([]) do |(key, raw_attributes), parsed|
        attributes = raw_attributes.respond_to?(:to_h) ? raw_attributes.to_h : {}
        next if truthy?(value_for(attributes, :remove))
        next if blank_group?(attributes)

        name = value_for(attributes, :name).to_s.strip
        asset_type_key = AssetType.normalize_key(value_for(attributes, :asset_type_key))
        target_percentage = decimal(value_for(attributes, :target_percentage), "group #{name.presence || key}")
        next unless valid_group_header?(name, asset_type_key, target_percentage)

        members = parse_group_members(
          value_for(attributes, :members).to_h, asset_type_key, name
        )
        parsed << GroupDefinition.new(name, asset_type_key, target_percentage, members)
      end
    end

    def parse_group_members(raw_members, asset_type_key, group_name)
      raw_members.each_with_object([]) do |(id, raw_attributes), parsed|
        attributes = raw_attributes.respond_to?(:to_h) ? raw_attributes.to_h : {}
        next unless truthy?(value_for(attributes, :selected)) || truthy?(value_for(attributes, :included))

        instrument = open_instruments_by_id[id.to_i]
        unless instrument
          errors << "Instrument #{id} must have an open position before it can be grouped."
          next
        end
        if instrument.asset_type != asset_type_key
          errors << "Instrument #{id} must use the #{AssetType.label_for(asset_type_key)} asset type for group #{group_name}."
          next
        end

        purchase_policy = value_for(attributes, :purchase_policy).to_s
        unless %w[buy hold].include?(purchase_policy)
          errors << "Instrument #{id} has an invalid group purchase policy."
          next
        end
        parsed << MemberDefinition.new(instrument, purchase_policy)
      end
    end

    def validate_totals(asset_target_values, instrument_target_values, group_definitions)
      if asset_target_values.empty?
        errors << "Choose at least one asset type target."
      elsif asset_target_values.values.sum != BigDecimal("100")
        errors << "Asset type targets must total 100%."
      end

      grouped_targets = instrument_target_values.group_by { |instrument, _percentage| instrument.asset_type }
      groups_by_asset_type = group_definitions.group_by(&:asset_type_key)
      grouped_instrument_ids = group_definitions.flat_map { |group| group.members.map { |member| member.instrument.id } }

      if grouped_instrument_ids.uniq.length != grouped_instrument_ids.length
        errors << "An instrument can belong to only one allocation group."
      end

      instrument_target_values.each_key do |instrument|
        next unless grouped_instrument_ids.include?(instrument.id)

        errors << "Instrument #{instrument.ticker} cannot have an individual target and a group target."
      end

      group_definitions.each do |group|
        if group.members.length < 2
          errors << "Group #{group.name} must include at least two instruments."
        elsif group.members.none? { |member| member.purchase_policy == "buy" }
          errors << "Group #{group.name} must have at least one instrument marked Buy."
        end
      end

      group_names = group_definitions.map { |group| group.name.downcase }
      errors << "Allocation group names must be unique." if group_names.uniq.length != group_names.length

      (grouped_targets.keys | groups_by_asset_type.keys).each do |asset_type_key|
        unless asset_target_values.key?(asset_type_key)
          errors << "Add an asset type target for #{AssetType.label_for(asset_type_key)}."
          next
        end

        targets = grouped_targets.fetch(asset_type_key, [])
        groups_for_type = groups_by_asset_type.fetch(asset_type_key, [])
        total = targets.sum { |_instrument, percentage| percentage } +
          groups_for_type.sum(&:target_percentage)
        available_count = open_instruments_by_id.values.count { |instrument| instrument.asset_type == asset_type_key }
        grouped_count = groups_for_type.sum { |group| group.members.map(&:instrument).uniq.length }
        bucket_count = targets.length + groups_for_type.length
        ungrouped_count = available_count - grouped_count
        next if total <= BigDecimal("100") && bucket_count < groups_for_type.length + ungrouped_count
        next if total == BigDecimal("100")

        message = groups_for_type.empty? ? "Instrument targets for #{AssetType.label_for(asset_type_key)} must total 100%." :
          "Instrument and group targets for #{AssetType.label_for(asset_type_key)} must total 100%."
        errors << message
      end

      asset_target_values.each_key do |asset_type_key|
        next if open_instruments_by_id.values.any? { |instrument| instrument.asset_type == asset_type_key }

        errors << "Choose instruments for #{AssetType.label_for(asset_type_key)}."
      end
    end

    def persist(asset_target_values, instrument_target_values, group_definitions)
      plan.transaction do
        plan.instrument_targets.delete_all
        plan.asset_targets.delete_all
        plan.allocation_groups.destroy_all
        asset_target_values.each do |asset_type_key, percentage|
          plan.asset_targets.create!(asset_type_key:, target_percentage: percentage)
        end
        instrument_target_values.each do |instrument, percentage|
          plan.instrument_targets.create!(
            instrument:, asset_type_key: instrument.asset_type, target_percentage: percentage
          )
        end
        group_definitions.each do |group_definition|
          group = plan.allocation_groups.create!(
            name: group_definition.name,
            asset_type_key: group_definition.asset_type_key,
            target_percentage: group_definition.target_percentage
          )
          group_definition.members.each do |member|
            group.members.create!(instrument: member.instrument, purchase_policy: member.purchase_policy)
          end
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

    def blank_group?(attributes)
      members = value_for(attributes, :members).to_h
      no_members_selected = members.values.none? do |raw_attributes|
        member_attributes = raw_attributes.respond_to?(:to_h) ? raw_attributes.to_h : {}
        truthy?(value_for(member_attributes, :selected)) || truthy?(value_for(member_attributes, :included))
      end
      value_for(attributes, :name).blank? && value_for(attributes, :target_percentage).blank? && no_members_selected
    end

    def valid_group_header?(name, asset_type_key, target_percentage)
      if name.blank?
        errors << "Allocation groups need a name."
        return false
      end
      unless AssetType.valid_key?(asset_type_key)
        errors << "Asset type #{asset_type_key} is not registered."
        return false
      end
      return false unless target_percentage

      unless target_percentage.positive?
        errors << "Group #{name} must have a positive target percentage."
        return false
      end
      true
    end

    def value_for(attributes, key)
      attributes[key.to_s] || attributes[key.to_sym]
    end

    def truthy?(value)
      value.to_s.in?(%w[1 true])
    end
  end
end
