module CorporateActionImports
  Candidate = Data.define(
    :kind, :source_reference, :event_on, :amount_per_share, :ratio_numerator,
    :ratio_denominator, :currency, :provider_symbol, :provider_exchange,
    :raw_payload, :warnings
  ) do
    def kind?(value) = kind.to_s == value.to_s
    def dividend? = kind?(:dividend)
    def jcp? = kind?(:jcp)
    def cash_action? = dividend? || jcp?
    def split? = kind?(:split)
    def reverse_split? = kind?(:reverse_split)
    def share_bonus? = kind?(:share_bonus)
    def quantity_action? = split? || reverse_split? || share_bonus?
  end
end
