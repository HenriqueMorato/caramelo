module CorporateActionImports
  class ManualActionIndex
    def initialize(user:, instrument:)
      @user = user
      @instrument = instrument
    end

    def include?(kind:, date:)
      keys.key?([ normalized_action_kind(kind), date ])
    end

    private

    attr_reader :user, :instrument

    def keys
      @keys ||= user.corporate_actions.where(
        instrument:, source: "manual"
      ).where.not(status: :reversed).pluck(:kind, :effective_on, :ex_date, :paid_on).each_with_object({}) do |row, result|
        kind, effective_on, ex_date, paid_on = row
        [ effective_on, ex_date, paid_on ].compact.uniq.each do |date|
          result[[ normalized_action_kind(kind), date ]] = true
        end
      end
    end

    def normalized_action_kind(kind)
      return "split" if CorporateActionImport.stock_split_kind?(kind)

      kind.to_s
    end
  end
end
