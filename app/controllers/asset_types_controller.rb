class AssetTypesController < ApplicationController
  before_action :ensure_defaults
  before_action :set_asset_type, only: %i[ edit update destroy ]

  def index
    @asset_types = AssetType.with_instrument_counts.alphabetical
  end

  def new
    @asset_type = AssetType.new
  end

  def create
    @asset_type = AssetType.new(asset_type_params)

    if @asset_type.save
      redirect_to asset_types_path, notice: t("notices.Created", model: AssetType.model_name.human)
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @asset_type.update(asset_type_params)
      redirect_to asset_types_path, notice: t("notices.Updated", model: AssetType.model_name.human), status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    if @asset_type.destroy
      redirect_to asset_types_path, notice: t("notices.Deleted", model: AssetType.model_name.human), status: :see_other
    else
      redirect_to asset_types_path, alert: @asset_type.errors.full_messages.to_sentence, status: :see_other
    end
  end

  private

  def ensure_defaults
    AssetType.ensure_defaults!
  end

  def set_asset_type
    @asset_type = AssetType.find(params.expect(:id))
  end

  def asset_type_params
    params.expect(asset_type: [ :name ])
  end
end
