class CorporateActionImportsController < ApplicationController
  allow_unauthenticated_access

  before_action :set_import, only: %i[ edit update confirm ignore ]
  before_action :set_form_options, only: %i[ index edit update ]
  before_action :set_edit_presenter, only: %i[ edit update ]

  def index
    @status_filter = params[:status].presence_in(%w[all reviewable confirmed ignored failed]) || "reviewable"
    @imports = imports_scope
    @from = parse_date(params[:from]) || default_from
    @to = parse_date(params[:to]) || Date.current
    prepare_scan_state
  end

  def create
    from = scan_date(:from)
    to = scan_date(:to)
    validate_scan_range!(from:, to:)
    source = scan_source
    instrument = scan_instrument
    scope = CorporateActionImports::ScanStatus.scope(
      user: owner, from:, to:, source:, instrument_id: instrument&.id
    )
    if (active_scan = scan_in_progress(scope))
      redirect_to scan_path(from:, to:, source:, instrument_id: instrument&.id, run_id: active_scan.run_id),
        notice: t("corporate_action_imports.notices.scan_already_running")
      return
    end

    refresh = CorporateActionImports::ScanStatus.enqueue(scope:)
    begin
      ScanCorporateActionImportsJob.perform_later(
        user_id: owner.id, from: from.iso8601, to: to.iso8601, source:,
        instrument_id: instrument&.id, scope:, scan_run_id: refresh.run_id
      )
    rescue StandardError => error
      CorporateActionImports::ScanStatus.fail(scope:, run_id: refresh.run_id, error:)
      redirect_to scan_path(from:, to:, source:, instrument_id: instrument&.id, run_id: refresh.run_id),
        alert: t("corporate_action_imports.notices.scan_start_failed")
      return
    end

    redirect_to scan_path(from:, to:, source:, instrument_id: instrument&.id, run_id: refresh.run_id),
      notice: t("corporate_action_imports.notices.scan_started")
  rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => error
    redirect_to corporate_action_imports_path, alert: error.message
  end

  def edit
  end

  def update
    result = CorporateActionImports::Review.call(import: @import, attributes: review_params)
    if result.success?
      redirect_to corporate_action_imports_path, notice: t("corporate_action_imports.notices.review_saved")
    else
      @edit = build_edit_presenter
      flash.now[:alert] = result.error
      render :edit, status: :unprocessable_content
    end
  end

  def confirm
    result = CorporateActionImports::Confirmation.call(import: @import, attributes: review_params)
    redirect_to corporate_action_imports_path, flash: confirmation_flash(result)
  end

  def ignore
    CorporateActionImports::Ignore.call(import: @import)
    redirect_to corporate_action_imports_path, notice: t("corporate_action_imports.notices.ignored")
  end

  def bulk_confirm
    summary = confirm_imports(selected_imports)
    redirect_to corporate_action_imports_path, notice: summary_notice(summary)
  end

  def bulk_ignore
    imports = selected_imports
    imports.each { |import| CorporateActionImports::Ignore.call(import:) }
    redirect_to corporate_action_imports_path, notice: t("corporate_action_imports.notices.ignored_many", count: imports.size)
  end

  private

  def owner
    @owner ||= User.owner
  end

  def set_import
    @import = owner.corporate_action_imports.friendly.find(params.expect(:id))
  end

  def set_form_options
    @instruments = Instrument.where(id: owner.trades.select(:instrument_id)).alphabetical.to_a
    @institutions = if @import&.instrument
      owner.institutions.where(
        id: owner.trades.where(instrument: @import.instrument).where.not(institution_id: nil)
          .select(:institution_id)
      ).order(:name).to_a
    else
      []
    end
  end

  def set_edit_presenter
    @edit = build_edit_presenter
  end

  def build_edit_presenter
    CorporateActionImports::EditPresenter.new(import: @import, institutions: @institutions)
  end

  def imports_scope
    scope = owner.corporate_action_imports.includes(:instrument)
    case @status_filter
    when "reviewable" then scope.reviewable
    when "all" then scope
    else scope.where(status: @status_filter)
    end.reverse_chronological
  end

  def scan_params
    (params[:scan] || ActionController::Parameters.new).permit(:from, :to, :source, :instrument_id)
  end

  def scan_date(key)
    value = scan_params[key]
    date = parse_date(value)
    raise ArgumentError, t("corporate_action_imports.errors.invalid_date") unless date

    date
  end

  def scan_source
    scan_params[:source].presence_in(%w[yahoo_finance]) || "yahoo_finance"
  end

  def validate_scan_range!(from:, to:)
    return if from <= to && to <= Date.current

    raise ArgumentError, t("corporate_action_imports.errors.invalid_date")
  end

  def scan_instrument
    id = scan_params[:instrument_id]
    return if id.blank?

    instrument_id = Integer(id, exception: false)
    unless owner.trades.exists?(instrument_id:)
      raise ArgumentError, t("corporate_action_imports.errors.invalid_instrument")
    end

    Instrument.find(instrument_id)
  end

  def parse_date(value)
    return value if value.is_a?(Date)
    return if value.blank?

    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def default_from
    owner.trades.minimum(:traded_on) || Date.current - 1.year
  end

  def prepare_scan_state
    @scan_source = params[:source].presence_in(%w[yahoo_finance]) || "yahoo_finance"
    @scan_instrument_id = Integer(params[:instrument_id], exception: false) if params[:instrument_id].present?
    @scan_refresh_path = scan_path(
      from: @from, to: @to, source: @scan_source, instrument_id: @scan_instrument_id
    )
    return unless params[:scan_run_id].present?

    @scan_scope = CorporateActionImports::ScanStatus.scope(
      user: owner, from: @from, to: @to, source: @scan_source, instrument_id: @scan_instrument_id
    )
    @scan_state = RefreshStatus::State.read(@scan_scope)
    return if @scan_state&.run_id.to_s == params[:scan_run_id].to_s

    @scan_state = nil
  end

  def scan_in_progress(scope)
    state = RefreshStatus::State.read(scope)
    state if state&.active? && !state.interrupted?
  end

  def scan_path(from:, to:, source:, instrument_id: nil, run_id: nil)
    CorporateActionImports::ScanStatus.path(
      from:, to:, source:, instrument_id:, run_id:
    )
  end

  def review_params
    params.fetch(:corporate_action_import, {}).permit(
      :kind, :paid_on, :ex_date, :gross_amount, :gross_amount_cents,
      :withholding_tax, :withholding_tax_cents, :effective_on,
      :ratio_numerator, :ratio_denominator, :institution_id, :accept_provider_update
    ).to_h.symbolize_keys
  end

  def selected_imports
    ids = Array(params[:import_ids]).filter_map { |id| Integer(id, exception: false) }
    owner.corporate_action_imports.where(id: ids).to_a
  end

  def confirm_imports(imports)
    imports.each_with_object(Hash.new(0)) do |import, summary|
      result = CorporateActionImports::Confirmation.call(import:)
      summary[result.status] += 1
    end
  end

  def confirmation_flash(result)
    if result.confirmed?
      { notice: t("corporate_action_imports.notices.confirmed") }
    elsif result.duplicate?
      { notice: t("corporate_action_imports.notices.duplicate") }
    elsif result.ambiguous?
      { alert: result.error || t("corporate_action_imports.notices.not_confirmed") }
    else
      { alert: result.error || t("corporate_action_imports.notices.not_confirmed") }
    end
  end

  def summary_notice(summary)
    t(
      "corporate_action_imports.notices.bulk_complete",
      confirmed: summary.fetch(:confirmed, 0), duplicate: summary.fetch(:duplicate, 0),
      failed: summary.fetch(:failed, 0), skipped: summary.fetch(:ignored, 0) +
        summary.fetch(:conflict, 0) + summary.fetch(:ambiguous, 0)
    )
  end
end
