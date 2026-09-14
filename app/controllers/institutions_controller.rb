class InstitutionsController < ApplicationController
  allow_unauthenticated_access

  before_action :set_institution, only: %i[ show edit update destroy ]

  def index
    @institutions = owner.institutions.alphabetical
  end

  def show
  end

  def new
    @institution = owner.institutions.new
  end

  def create
    @institution = owner.institutions.new(institution_params)

    if @institution.save
      redirect_to @institution, notice: t("notices.Created", model: Institution.model_name.human)
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @institution.update(institution_params)
      redirect_to @institution, notice: t("notices.Updated", model: Institution.model_name.human), status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    if @institution.destroy
      redirect_to institutions_path, notice: t("notices.Deleted", model: Institution.model_name.human), status: :see_other
    else
      redirect_to @institution, alert: @institution.errors.full_messages.to_sentence, status: :see_other
    end
  end

  private

  def owner
    @owner ||= User.owner
  end

  def set_institution
    @institution = owner.institutions.friendly.find(params.expect(:id))
  end

  def institution_params
    params.expect(institution: %i[name notes active])
  end
end
