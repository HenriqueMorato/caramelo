class AssetTypesController < ApplicationController
  before_action :ensure_defaults
  before_action :set_asset_type, only: %i[ edit update destroy ]

  def index
    @asset_types = AssetType.with_instrument_counts.alphabetical.limit(AssetType::MAX_CATALOG_SIZE)
  end

  def new
    @asset_type = AssetType.new
  end

  def create
    @asset_type = AssetType.new(asset_type_params)

    if save_asset_type
      redirect_to asset_types_path, notice: t("notices.Created", model: AssetType.model_name.human)
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if update_asset_type
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
  rescue ActiveRecord::InvalidForeignKey
    @asset_type.errors.add(:base, :cannot_destroy_with_instruments)
    redirect_to asset_types_path, alert: @asset_type.errors.full_messages.to_sentence, status: :see_other
  end

  private

  def ensure_defaults
    AssetType.ensure_defaults!
  end

  def set_asset_type
    @asset_type = AssetType.friendly.find(params.expect(:id))
  end

  def asset_type_params
    params.expect(asset_type: [ :name ])
  end

  def save_asset_type
    2.times do |attempt|
      return true if @asset_type.save
    rescue ActiveRecord::RecordNotUnique
      unless attempt.zero?
        @asset_type.errors.add(:name, :taken)
        return false
      end

      @asset_type.key = nil
    end

    false
  end

  def update_asset_type
    @asset_type.update(asset_type_params)
  rescue ActiveRecord::RecordNotUnique
    @asset_type.errors.add(:name, :taken)
    false
  end
end
