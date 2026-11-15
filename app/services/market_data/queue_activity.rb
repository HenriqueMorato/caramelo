module MarketData
  class QueueActivity
    EXECUTION_CLASSES = [
      SolidQueue::ReadyExecution,
      SolidQueue::ScheduledExecution,
      SolidQueue::ClaimedExecution,
      SolidQueue::BlockedExecution
    ].freeze

    def self.active_job?(class_name:, &matcher)
      new.active_job?(class_name:, &matcher)
    end

    def initialize(job_scope: nil, failed_execution: SolidQueue::FailedExecution,
      execution_classes: EXECUTION_CLASSES)
      @job_scope = job_scope
      @failed_execution = failed_execution
      @execution_classes = execution_classes
    end

    def active_job?(class_name:)
      jobs.where(class_name:).find_each do |job|
        next unless job.finished_at.nil?
        next if failed_execution.exists?(job_id: job.id)

        arguments = job.arguments.fetch("arguments", []).first.to_h.symbolize_keys
        next unless yield(arguments)
        return true if execution_exists?(job.id)
      end

      false
    end

    private

    attr_reader :job_scope, :failed_execution, :execution_classes

    def jobs
      job_scope || SolidQueue::Job
    end

    def execution_exists?(job_id)
      execution_classes.any? { |execution_class| execution_class.exists?(job_id:) }
    end
  end
end
