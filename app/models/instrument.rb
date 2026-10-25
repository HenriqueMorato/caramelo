class Instrument < ApplicationRecord
  extend FriendlyId

  US_EXCHANGES = %w[ARCX XNAS XNYS].freeze
  FRACTIONAL_QUANTITY_STEP = BigDecimal("0.001")
  WHOLE_QUANTITY_STEP = BigDecimal("1")
  UCITS_PATTERN = /\bUCITS\b/i

  AssetType::SYSTEM_KEYS.each do |key|
    define_method("#{key}?") { asset_type == key }
    define_method("#{key}!") { update!(asset_type: key) }
  end

  friendly_id :slug_candidates, use: :slugged

  before_validation :apply_default_quantity_step, on: :create
  before_destroy :prevent_destroy_when_referenced

  has_many :instrument_performance_observations, dependent: :delete_all
  has_many :instrument_performance_materializations, dependent: :delete_all
  belongs_to :asset_type_record, class_name: "AssetType", foreign_key: :asset_type,
    primary_key: :key, inverse_of: :instruments, optional: true
  has_many :trades, dependent: :restrict_with_error
  has_many :corporate_actions, dependent: :restrict_with_error
  has_many :corporate_action_imports, dependent: :delete_all
  has_many :corporate_action_import_scans, dependent: :delete_all
  has_many :daily_closing_prices, dependent: :restrict_with_error
  has_many :position_materializations, dependent: :delete_all
  has_many :portfolio_allocation_instrument_targets, dependent: :restrict_with_error,
    inverse_of: :instrument

  normalizes :ticker, with: ->(ticker) { ticker.strip.upcase }
  normalizes :exchange, with: ->(exchange) { exchange.strip.upcase }
  normalizes :name, with: ->(name) { name.strip.squish }
  normalizes :currency, with: ->(currency) { currency.strip.upcase }
  normalizes :asset_type, with: ->(asset_type) { asset_type.to_s.strip.downcase }

  validates :ticker, presence: true, uniqueness: { scope: :exchange, case_sensitive: false }
  validates :exchange, presence: true, format: { with: /\A[A-Z0-9]{4}\z/ }
  validates :name, presence: true
  validates :currency, presence: true, iso_currency: true
  validates :quantity_step, numericality: { greater_than: 0 }
  validates :asset_type, presence: true
  validate :asset_type_is_registered
  validate :identity_unchanged_when_referenced, if: :identity_changed?

  scope :alphabetical, -> { order(:ticker, :exchange) }

  def default_quantity_step
    fractional_quantity_step? ? FRACTIONAL_QUANTITY_STEP : WHOLE_QUANTITY_STEP
  end

  def fractional_quantity_step?
    us_listing? || ucits?
  end

  def us_listing?
    US_EXCHANGES.include?(exchange)
  end

  def ucits?
    name.to_s.match?(UCITS_PATTERN)
  end

  def quantity_step=(value)
    @quantity_step_explicitly_assigned = true
    super
  end

  def self.asset_types
    AssetType.catalog.to_h { |asset_type| [ asset_type.key, asset_type.key ] }
  end

  def deletion_blocked?
    trades.exists? || corporate_actions.exists? || corporate_action_imports.exists? ||
      corporate_action_import_scans.exists? || daily_closing_prices.exists? ||
      HistoricalDataBackfill.where(instrument: self).exists?
  end

  private

  def apply_default_quantity_step
    return if @quantity_step_explicitly_assigned || will_save_change_to_quantity_step?

    write_attribute(:quantity_step, default_quantity_step)
  end

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

  def prevent_destroy_when_referenced
    return if trades.exists? || corporate_actions.exists? || daily_closing_prices.exists?
    return unless deletion_blocked?

    errors.add(:base, :cannot_destroy_with_activity)
    throw(:abort)
  end

  def asset_type_is_registered
    return if AssetType.valid_key?(asset_type)

    errors.add(:asset_type, :inclusion)
  end

  def referenced?
    trades.exists? || corporate_actions.exists? || corporate_action_imports.exists? ||
      corporate_action_import_scans.exists? || daily_closing_prices.exists? ||
      instrument_performance_observations.exists? || instrument_performance_materializations.exists? ||
      position_materializations.exists? || HistoricalDataBackfill.where(instrument: self).exists?
  end
end
