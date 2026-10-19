require "test_helper"

class AssetTypeTest < ActiveSupport::TestCase
  test "ensures the built-in catalog without changing edited names" do
    AssetType.ensure_defaults!
    AssetType.find_by!(key: "stock").update!(name: "Equities")

    AssetType.ensure_defaults!

    assert_equal "Equities", AssetType.find_by!(key: "stock").name
    assert_equal AssetType::SYSTEM_KEYS.sort, AssetType.where(system: true).pluck(:key).sort
  end

  test "creates a custom type with a stable key derived from its name" do
    asset_type = AssetType.create!(name: "  Real   Estate  ")

    assert_equal "real_estate", asset_type.key
    assert_not asset_type.system?
    assert_equal "Real Estate", asset_type.name
    assert_equal "Real Estate", AssetType.label_for("real_estate")
  end

  test "normalizes an explicit key and exposes catalog helpers" do
    asset_type = AssetType.create!(key: "  digital_assets ", name: "Digital assets")
    AssetType.ensure_defaults!

    assert_equal "digital_assets", asset_type.key
    assert_includes AssetType.options, [ "Digital assets", "digital_assets" ]
    assert AssetType.valid_key?("stock")
    assert AssetType.valid_key?(" STOCK ")
    assert AssetType.valid_key?("digital_assets")
    refute AssetType.valid_key?("not_registered")
    assert_equal "Digital assets", AssetType.label_for(" DIGITAL_ASSETS ")
    assert_equal "Not registered", AssetType.label_for("not_registered")
  end

  test "requires a nonblank name when a key is not supplied" do
    asset_type = AssetType.new(name: "")

    assert_not asset_type.valid?
    assert_empty asset_type.key
    assert_includes asset_type.errors[:name], "can't be blank"
  end

  test "creates a stable key for a name without a Latin transliteration" do
    asset_type = AssetType.create!(name: "不動産")

    assert_equal "不動産", asset_type.name
    assert_match(/\Atype_[a-f0-9]{27}\z/, asset_type.key)
    assert_operator asset_type.key.length, :<=, AssetType::KEY_MAX_LENGTH
  end

  test "keeps generated keys unique when long names share a prefix" do
    first = AssetType.create!(name: "International developed markets equities")
    second = AssetType.create!(name: "International developed markets bonds")

    assert_operator first.key.length, :<=, AssetType::KEY_MAX_LENGTH
    assert_operator second.key.length, :<=, AssetType::KEY_MAX_LENGTH
    assert_not_equal first.key, second.key
    assert_match(/\A[a-z0-9]+(?:_[a-z0-9]+)*\z/, second.key)
  end

  test "keeps the key stable when a type is renamed" do
    asset_type = AssetType.create!(name: "Cash")
    instrument = Instrument.create!(ticker: "CASH", exchange: "BVMF", name: "Cash balance", currency: "BRL", asset_type: asset_type.key)

    asset_type.update!(name: "Cash reserve")

    assert_equal "cash", asset_type.reload.key
    assert_equal "Cash reserve", instrument.reload.asset_type_record.name
  end

  test "does not delete a built-in or used custom type" do
    AssetType.ensure_defaults!
    built_in = AssetType.find_by!(key: "stock")
    custom = AssetType.create!(name: "Private credit")
    Instrument.create!(ticker: "PRIV", exchange: "BVMF", name: "Private credit", currency: "BRL", asset_type: custom.key)

    assert_not built_in.destroy
    assert_includes built_in.errors.full_messages, "Cannot delete a built-in asset type"
    assert_not custom.destroy
    assert_includes custom.errors.full_messages, "Cannot delete an asset type used by instruments"
  end

  test "allows an unused custom type to be deleted" do
    asset_type = AssetType.create!(name: "Collectibles")

    assert_difference("AssetType.count", -1) { asset_type.destroy! }
  end
end
