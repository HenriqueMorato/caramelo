require "digest"

module CorporateActionImports
  class ScanStatus
    SCOPE_PREFIX = "corporate_action_imports_scan:"
    STREAM_PREFIX = "corporate_action_imports_scan"
    TARGET = "corporate-action-scan-status"

    class << self
      def scope(user:, from:, to:, source:, instrument_id:)
        [
          SCOPE_PREFIX.delete_suffix(":"),
          user.id,
          source,
          instrument_id || "all",
          Date.iso8601(from.to_s),
          Date.iso8601(to.to_s)
        ].join(":")
      end

      def stream_name(scope)
        "#{STREAM_PREFIX}:#{Digest::SHA256.hexdigest(scope.to_s)}"
      end

      def path(from:, to:, source:, instrument_id: nil, run_id: nil)
        parameters = { from: from.to_s, to: to.to_s, source: }
        parameters[:instrument_id] = instrument_id if instrument_id.present?
        parameters[:scan_run_id] = run_id if run_id.present?
        Rails.application.routes.url_helpers.corporate_action_imports_path(parameters)
      end

      def enqueue(scope:, total_count: 1, run_id: SecureRandom.uuid)
        RefreshStatus::State.write(
          scope:, run_id:, status: "queued", processed_count: 0, total_count:
        )
      end

      def start(scope:, run_id:)
        return unless current?(scope:, run_id:)

        state = RefreshStatus::State.read(scope)
        write(state, status: "running", started_at: state.started_at || Time.current, finished_at: nil,
          error_class: nil, error_message: nil)
      end

      def retrying(scope:, run_id:)
        return unless current?(scope:, run_id:)

        state = RefreshStatus::State.read(scope)
        write(state, status: "running", finished_at: nil, error_class: nil, error_message: nil)
      end

      def succeed(scope:, run_id:)
        return unless current?(scope:, run_id:)

        state = RefreshStatus::State.read(scope)
        write(state, status: "succeeded", processed_count: state.total_count || 1,
          finished_at: Time.current, error_class: nil, error_message: nil)
      end

      def fail(scope:, run_id:, error:)
        return unless current?(scope:, run_id:)

        state = RefreshStatus::State.read(scope)
        write(state, status: "failed", finished_at: Time.current, error_class: error.class.name,
          error_message: error.message.to_s.truncate(500))
      end

      def current?(scope:, run_id:)
        run_id.present? && RefreshStatus::State.read(scope)&.run_id == run_id
      end

      def broadcast(scope:, refresh_path:, reload: false)
        state = RefreshStatus::State.read(scope)
        return unless state

        Turbo::StreamsChannel.broadcast_update_to(
          stream_name(scope), target: TARGET, partial: "corporate_action_imports/scan_status",
          locals: { state:, refresh_path:, reload: }, method: :morph
        )
      end

      private

      def write(state, **attributes)
        RefreshStatus::State.write(
          scope: state.scope,
          run_id: state.run_id,
          status: attributes.fetch(:status, state.status),
          started_at: attributes.fetch(:started_at, state.started_at),
          finished_at: attributes.fetch(:finished_at, state.finished_at),
          error_class: attributes.fetch(:error_class, state.error_class),
          error_message: attributes.fetch(:error_message, state.error_message),
          processed_count: attributes.fetch(:processed_count, state.processed_count),
          total_count: attributes.fetch(:total_count, state.total_count)
        )
      end
    end
  end
end
