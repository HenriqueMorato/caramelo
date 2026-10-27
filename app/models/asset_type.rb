require "digest"

class AssetType < ApplicationRecord
  extend FriendlyId

  friendly_id :key, use: :finders

  KEY_MAX_LENGTH = 32
  MAX_CUSTOM_TYPES = 100
  FALLBACK_KEY_PREFIX = "type_"
  SYSTEM_DEFAULTS = [
    { key: "stock", name: "Stock", system: true },
    { key: "etf", name: "ETF", system: true },
    { key: "fund", name: "Fund", system: true },
    { key: "bond", name: "Bond", system: true },
    { key: "crypto", name: "Crypto", system: true },
    { key: "other", name: "Other", system: true }
  ].map(&:freeze).freeze
  SYSTEM_KEYS = SYSTEM_DEFAULTS.map { |attributes| attributes.fetch(:key) }.freeze
  MAX_CATALOG_SIZE = SYSTEM_KEYS.length + MAX_CUSTOM_TYPES

  has_many :instruments, foreign_key: :asset_type, primary_key: :key,
    inverse_of: :asset_type_record
  has_many :portfolio_allocation_asset_targets, foreign_key: :asset_type_key,
    primary_key: :key, inverse_of: :asset_type
  has_many :portfolio_allocation_instrument_targets, foreign_key: :asset_type_key,
    primary_key: :key, inverse_of: :asset_type

  normalizes :key, with: ->(value) { value.to_s.strip.downcase }
  normalizes :name, with: ->(value) { value.to_s.strip.squish }

  attr_readonly :key, :system

  before_validation :assign_key, on: :create
  before_validation :sync_normalized_name
  before_destroy :prevent_destroy

  validates :key, presence: true, length: { maximum: KEY_MAX_LENGTH },
    format: { with: /\A[a-z0-9]+(?:_[a-z0-9]+)*\z/ },
    uniqueness: { case_sensitive: false }
  validates :name, presence: true, length: { maximum: 64 },
    uniqueness: { case_sensitive: false }
  validate :custom_catalog_capacity, on: :create

  scope :alphabetical, -> { order(:name, :key) }
  scope :with_instrument_counts, -> {
    left_joins(:instruments)
      .select("asset_types.*, COUNT(instruments.id) AS instruments_count")
      .group("asset_types.id")
  }

  def self.ensure_defaults!
    SYSTEM_DEFAULTS.each do |attributes|
      find_or_create_by!(key: attributes.fetch(:key)) do |asset_type|
        asset_type.assign_attributes(attributes)
      end
    end
  end

  def self.catalog
    ensure_defaults!
    alphabetical.limit(MAX_CATALOG_SIZE).to_a
  end

  def self.options
    catalog.map { |asset_type| [ asset_type.name, asset_type.key ] }
  end

  def self.custom_count
    where(system: false).count
  end

  def self.valid_key?(key)
    normalized_key = normalize_key(key)
    SYSTEM_KEYS.include?(normalized_key) || exists?(key: normalized_key)
  end

  def self.label_for(key)
    normalized_key = normalize_key(key)
    labels_for([ normalized_key ]).fetch(normalized_key)
  end

  def self.labels_for(keys)
    normalized_keys = keys.map { |key| normalize_key(key) }.uniq
    names_by_key = where(key: normalized_keys).pluck(:key, :name).to_h

    normalized_keys.index_with do |normalized_key|
      names_by_key.fetch(normalized_key) do
        I18n.t("instrument_types.#{normalized_key}", default: normalized_key.humanize)
      end
    end
  end

  def self.normalize_key(key)
    key.to_s.strip.downcase
  end

  private

  def sync_normalized_name
    self.normalized_name = name.to_s.downcase
  end

  def custom_catalog_capacity
    return if system? || self.class.custom_count < MAX_CUSTOM_TYPES

    errors.add(:base, :catalog_limit, count: MAX_CUSTOM_TYPES)
  end

  def assign_key
    return if key.present?

    base_key = name.to_s.parameterize(separator: "_")
    base_key = fallback_key if base_key.blank? && name.present?
    self.key = base_key.present? ? available_key(base_key) : ""
  end

  def fallback_key
    digest = Digest::SHA256.hexdigest(name.to_s)
    "#{FALLBACK_KEY_PREFIX}#{digest.first(KEY_MAX_LENGTH - FALLBACK_KEY_PREFIX.length)}"
  end

  def available_key(base_key)
    candidate = trim_key(base_key[0, KEY_MAX_LENGTH])
    suffix = 2

    while self.class.exists?(key: candidate)
      suffix_part = "_#{suffix}"
      stem_length = [ KEY_MAX_LENGTH - suffix_part.length, 1 ].max
      stem = trim_key(base_key[0, stem_length])
      candidate = "#{stem}#{suffix_part}"
      suffix += 1
    end

    candidate
  end

  def trim_key(value)
    value.to_s.sub(/_+\z/, "")
  end

  def prevent_destroy
    if system?
      errors.add(:base, :cannot_destroy_system)
    elsif instruments.exists?
      errors.add(:base, :cannot_destroy_with_instruments)
    end

    throw(:abort) if errors.any?
  end
end
