require "test_helper"

class AssetTypesControllerTest < ActionDispatch::IntegrationTest
  setup do
    AssetType.ensure_defaults!
  end

  test "lists built-in and custom asset types" do
    custom = AssetType.create!(name: "Real estate")

    get asset_types_url

    assert_response :success
    assert_select "h1", "Asset types"
    assert_select "#asset_type_#{custom.id}", text: /Real estate/
    assert_select "#asset_type_#{AssetType.find_by!(key: "stock").id}", text: /Stock/
  end

  test "creates a custom asset type" do
    assert_difference("AssetType.count") do
      post asset_types_url, params: { asset_type: { name: "  Real   Estate  " } }
    end

    assert_redirected_to asset_types_url
    assert_equal "real_estate", AssetType.order(:id).last.key
    assert_equal "Real Estate", AssetType.order(:id).last.name
  end

  test "updates an asset type name without changing its key" do
    asset_type = AssetType.create!(name: "Cash")

    patch asset_type_url(asset_type), params: { asset_type: { name: "Cash reserve" } }

    assert_redirected_to asset_types_url
    assert_equal "cash", asset_type.reload.key
    assert_equal "Cash reserve", asset_type.name
  end

  test "renders the new and edit forms" do
    get new_asset_type_url
    assert_response :success
    assert_select "h1", "Add asset type"

    asset_type = AssetType.create!(name: "Cash")
    get edit_asset_type_url(asset_type)
    assert_response :success
    assert_select "h1", "Edit asset type"
    assert_select "input[name='asset_type[name]'][value='Cash']"
  end

  test "renders validation errors when a custom asset type update is invalid" do
    asset_type = AssetType.create!(name: "Cash")

    patch asset_type_url(asset_type), params: { asset_type: { name: "" } }

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Name can't be blank/
  end

  test "does not delete a built-in asset type" do
    asset_type = AssetType.find_by!(key: "stock")

    assert_no_difference("AssetType.count") { delete asset_type_url(asset_type) }

    assert_redirected_to asset_types_url
    assert_equal "Cannot delete a built-in asset type", flash[:alert]
  end

  test "deletes an unused custom asset type" do
    asset_type = AssetType.create!(name: "Collectibles")

    assert_difference("AssetType.count", -1) { delete asset_type_url(asset_type) }

    assert_redirected_to asset_types_url
  end

  test "keeps a used custom asset type" do
    asset_type = AssetType.create!(name: "Private credit")
    Instrument.create!(ticker: "PRIVATE", exchange: "BVMF", name: "Private credit", currency: "BRL",
      asset_type: asset_type.key)

    assert_no_difference("AssetType.count") { delete asset_type_url(asset_type) }

    assert_redirected_to asset_types_url
    assert_equal "Cannot delete an asset type used by instruments", flash[:alert]
  end

  test "renders validation errors when a custom asset type is invalid" do
    assert_no_difference("AssetType.count") do
      post asset_types_url, params: { asset_type: { name: "" } }
    end

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Name can't be blank/
  end

  test "requires a session when password authentication is enabled" do
    previous = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.authentication_mode = "password"
    sign_out

    get asset_types_url

    assert_redirected_to new_session_url
  ensure
    Rails.application.config.x.caramelo.authentication_mode = previous
  end

  test "allows the catalog in public single-account mode" do
    previous = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.authentication_mode = "public"
    sign_out

    get asset_types_url

    assert_response :success
  ensure
    Rails.application.config.x.caramelo.authentication_mode = previous
  end

  test "does not permit key or system changes through request parameters" do
    post asset_types_url, params: {
      asset_type: { name: "Private credit", key: "stock", system: true }
    }

    asset_type = AssetType.find_by!(name: "Private credit")
    assert_equal "private_credit", asset_type.key
    assert_not asset_type.system?
  end
end
