module ToastResponses
  private

  def respond_with_toast(message, alert: false, redirect_to:)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          "toast-feedback",
          partial: "layouts/toast",
          locals: { message:, alert: }
        )
      end
      format.html do
        redirect_to redirect_to,
          flash: { (alert ? :alert : :notice) => message }
      end
    end
  end

  def respond_with_status_toast(message, status:, redirect_to:)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          "toast-feedback",
          partial: "layouts/toast",
          locals: { message:, alert: true }
        )
      end
      format.html do
        redirect_to redirect_to, flash: { alert: message }, status:
      end
    end
  end
end
