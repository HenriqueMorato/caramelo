class MarketBenchmark < ApplicationRecord
  DEFAULTS = [
    { identifier: "IBOV", name: "Ibovespa", kind: "price", currency: "BRL", provider: "yahoo_finance", provider_identifier: "^BVSP" },
    { identifier: "SP500", name: "S&P 500", kind: "price", currency: "USD", provider: "yahoo_finance", provider_identifier: "^GSPC" },
    { identifier: "ACWI_IMI_NET", name: "MSCI ACWI IMI (Net Total Return proxy)", kind: "total_return", currency: "USD", provider: "yahoo_finance", provider_identifier: "IMID.L", return_convention: "net" },
    { identifier: "CDI", name: "CDI", kind: "rate", currency: "BRL", provider: "bcb", provider_identifier: "CDI" }
  ].freeze

  PERFORMANCE_KINDS = %w[price total_return rate].freeze
  RETURN_CONVENTIONS = %w[gross net].freeze

  def self.ensure_defaults!
    DEFAULTS.each do |attributes|
      find_or_create_by!(identifier: attributes.fetch(:identifier)) do |benchmark|
        benchmark.assign_attributes(attributes)
      end
    end
  end

  # A benchmark is a provider-backed reference series, not an owned instrument.
  # Price and total-return benchmarks use index levels; rate benchmarks (for
  # example, CDI) use the provider's daily rate representation. A total-return
  # benchmark records whether distributions are reinvested gross or net of tax.
  has_many :observations, class_name: "MarketBenchmarkObservation", dependent: :restrict_with_exception

  enum :kind, { price: "price", total_return: "total_return", rate: "rate" }, validate: true

  normalizes :name, with: ->(value) { value.strip }
  normalizes :identifier, :currency, with: ->(value) { value.strip.upcase }
  normalizes :kind, with: ->(value) { value.strip.downcase }
  normalizes :provider, with: ->(value) { value.strip.downcase }
  normalizes :provider_identifier, with: ->(value) { value.strip }
  normalizes :return_convention, with: ->(value) { value.to_s.strip.downcase.presence }

  validates :identifier, :name, :kind, :currency, :provider, :provider_identifier, presence: true
  validates :identifier, uniqueness: true, length: { maximum: 64 }
  validates :name, length: { maximum: 160 }
  validates :currency, iso_currency: true
  validates :provider, length: { maximum: 64 }
  validates :provider_identifier, length: { maximum: 128 }
  validates :return_convention, inclusion: { in: RETURN_CONVENTIONS }, allow_nil: true
  validate :total_return_requires_convention
  validate :return_convention_matches_kind

  def index?
    price? || total_return?
  end

  private

  def total_return_requires_convention
    return unless total_return? && return_convention.blank?

    errors.add(:return_convention, :blank)
  end

  def return_convention_matches_kind
    return if return_convention.blank? || total_return?

    errors.add(:return_convention, :invalid)
  end
end
