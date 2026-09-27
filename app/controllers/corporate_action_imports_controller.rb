class CorporateActionImportsController < ApplicationController
  allow_unauthenticated_access

  before_action :set_import, only: %i[ edit update confirm ignore ]
  before_action :set_form_options, only: %i[ index edit update ]

  def index
    @status_filter = params[:status].presence_in(%w[all reviewable confirmed ignored failed]) || "reviewable"
    @imports = imports_scope
    @from = parse_date(params[:from]) || default_from
    @to = parse_date(params[:to]) || Date.current
  end

  def create
    result = CorporateActionImports::Scan.call(
      user: owner, from: scan_date(:from), to: scan_date(:to),
      source: scan_source, instrument: scan_instrument
    )
    notice = t("corporate_action_imports.notices.scan_complete", count: result.imports.size)
    notice = "#{notice} #{t("corporate_action_imports.notices.scan_errors", count: result.error_count)}" if result.error_count.positive?
    redirect_to corporate_action_imports_path, notice:
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    redirect_to corporate_action_imports_path, alert: error.message
  end

  def edit
  end

  def update
    result = CorporateActionImports::Review.call(import: @import, attributes: review_params)
    if result.success?
      redirect_to corporate_action_imports_path, notice: t("corporate_action_imports.notices.review_saved")
    else
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

  def scan_instrument
    id = scan_params[:instrument_id]
    return if id.blank?

    @instruments_for_scan ||= owner.trades.where(instrument_id: id).distinct.pluck(:instrument_id)
    return unless @instruments_for_scan.include?(id.to_i)

    Instrument.find(id)
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

  def review_params
    params.fetch(:corporate_action_import, {}).permit(
      :kind, :paid_on, :ex_date, :gross_amount, :gross_amount_cents,
      :withholding_tax, :withholding_tax_cents, :effective_on,
      :ratio_numerator, :ratio_denominator, :institution_id
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
