class Instrument < ApplicationRecord
  extend FriendlyId

  friendly_id :slug_candidates, use: :slugged

  has_many :instrument_performance_observations, dependent: :delete_all
  has_many :instrument_performance_materializations, dependent: :delete_all
  has_many :trades, dependent: :restrict_with_error
  has_many :corporate_actions, dependent: :restrict_with_error
  has_many :corporate_action_imports, dependent: :delete_all
  has_many :corporate_action_import_scans, dependent: :delete_all
  has_many :daily_closing_prices, dependent: :restrict_with_error
  has_many :position_materializations, dependent: :delete_all

  enum :asset_type, {
    stock: "stock",
    etf: "etf",
    fund: "fund",
    bond: "bond",
    crypto: "crypto",
    other: "other"
  }, default: :other, validate: true

  normalizes :ticker, with: ->(ticker) { ticker.strip.upcase }
  normalizes :exchange, with: ->(exchange) { exchange.strip.upcase }
  normalizes :name, with: ->(name) { name.strip.squish }
  normalizes :currency, with: ->(currency) { currency.strip.upcase }

  validates :ticker, presence: true, uniqueness: { scope: :exchange, case_sensitive: false }
  validates :exchange, presence: true, format: { with: /\A[A-Z0-9]{4}\z/ }
  validates :name, presence: true
  validates :currency, presence: true, iso_currency: true
  validate :identity_unchanged_when_referenced, if: :identity_changed?

  scope :alphabetical, -> { order(:ticker, :exchange) }

  private

  def slug_candidates
    [ :ticker, [ :ticker, :exchange ] ]
  end

  def identity_changed?
    %w[ticker exchange currency].any? { |attribute| will_save_change_to_attribute?(attribute) }
  end

  def identity_unchanged_when_referenced
    return unless persisted? && referenced?

    %w[ticker exchange currency].each do |attribute|
      next unless will_save_change_to_attribute?(attribute)

      errors.add(attribute, :cannot_change_with_activity)
    end
  end

  def referenced?
    trades.exists? || corporate_actions.exists? || corporate_action_imports.exists? ||
      corporate_action_import_scans.exists? || daily_closing_prices.exists? ||
      instrument_performance_observations.exists? || instrument_performance_materializations.exists?
  end
end
