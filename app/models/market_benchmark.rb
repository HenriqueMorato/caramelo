class MarketBenchmark < ApplicationRecord
  DEFAULTS = [
    { identifier: "IBOV", name: "Ibovespa", kind: "price", currency: "BRL", provider: "yahoo_finance", provider_identifier: "^BVSP" },
    { identifier: "SP500", name: "S&P 500", kind: "price", currency: "USD", provider: "yahoo_finance", provider_identifier: "^GSPC" },
    { identifier: "CDI", name: "CDI", kind: "rate", currency: "BRL", provider: "bcb", provider_identifier: "CDI" }
  ].freeze

  # A benchmark is a provider-backed reference series, not an owned instrument.
  # Price benchmarks (for example, IBOV) use index levels; rate benchmarks
  # (for example, CDI) use the provider's daily rate representation.
  has_many :observations, class_name: "MarketBenchmarkObservation", dependent: :restrict_with_exception

  normalizes :name, with: ->(value) { value.strip }
  normalizes :identifier, :currency, with: ->(value) { value.strip.upcase }
  normalizes :kind, with: ->(value) { value.strip.downcase }
  normalizes :provider, with: ->(value) { value.strip.downcase }
  normalizes :provider_identifier, with: ->(value) { value.strip }

  validates :identifier, :name, :kind, :currency, :provider, :provider_identifier, presence: true
  validates :identifier, uniqueness: true, length: { maximum: 64 }
  validates :name, length: { maximum: 160 }
  validates :kind, inclusion: { in: %w[price rate] }
  validates :currency, iso_currency: true
  validates :provider, length: { maximum: 64 }
  validates :provider_identifier, length: { maximum: 128 }
end
