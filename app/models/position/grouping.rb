class Position
  class Grouping
    OPTIONS = %w[asset_type institution currency exchange].freeze
    INSTRUMENT_GROUPINGS = %w[asset_type currency exchange].freeze

    attr_reader :primary, :secondary

    def initialize(primary:, secondary:)
      @primary = normalize(primary)
      candidate = normalize(secondary)
      @secondary = candidate unless candidate == @primary
    end

    def include_institutions?
      [ primary, secondary ].include?("institution")
    end

    def options
      [ [ I18n.t("positions.index.No grouping"), "" ] ] + OPTIONS.map do |option|
        [ I18n.t("positions.index.Group by #{option}"), option ]
      end
    end

    def group(positions)
      return { nil => positions } unless primary

      positions.group_by { |position| value(position, primary) }.transform_values do |grouped_positions|
        secondary ? grouped_positions.group_by { |position| value(position, secondary) } : grouped_positions
      end
    end

    def prepare_labels(positions)
      return self unless [ primary, secondary ].include?("asset_type")

      keys = positions.filter_map { |position| position.instrument&.asset_type }.uniq
      @asset_type_labels = AssetType.labels_for(keys)
      self
    end

    def label(grouping, value)
      return value unless grouping == "asset_type"

      (@asset_type_labels || AssetType.labels_for([ value ])).fetch(AssetType.normalize_key(value))
    end

    def slot(value)
      return "primary" if value == primary
      return "secondary" if value == secondary

      ""
    end

    private

    def normalize(value)
      value.presence if OPTIONS.include?(value)
    end

    def value(position, grouping)
      return position.instrument.public_send(grouping) if INSTRUMENT_GROUPINGS.include?(grouping)

      # Keep one instrument row intact when trades span institutions; allocating
      # its quantity would change the position calculation's accounting scope.
      names = position.position_result.trades.filter_map { |trade| trade.institution&.name }.uniq
      names.one? ? names.first : names.any? ? "Multiple institutions" : "No institution"
    end
  end
end
