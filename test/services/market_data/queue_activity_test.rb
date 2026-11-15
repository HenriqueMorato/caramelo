require "test_helper"

class MarketData::QueueActivityTest < ActiveSupport::TestCase
  Job = Struct.new(:id, :finished_at, :arguments)
  JobScope = Struct.new(:records) do
    def where(class_name:)
      self.class.new(records.select { |job| job.arguments.fetch("job_class") == class_name })
    end

    def find_each
      each { |job| yield job }
    end

    def each(&block)
      records.each(&block)
    end
  end
  FailedExecution = Struct.new(:ids) do
    def exists?(job_id:)
      ids.include?(job_id)
    end
  end
  Execution = Struct.new(:ids) do
    def exists?(job_id:)
      ids.include?(job_id)
    end
  end

  test "finds a matching job with a live execution" do
    job = job(1, "BuildInstrumentPerformanceObservationsJob", instrument_id: 4)
    activity = build_activity([ job ], live_ids: [ 1 ])

    assert activity.active_job?(class_name: "BuildInstrumentPerformanceObservationsJob") { |args| args[:instrument_id] == 4 }
  end

  test "ignores finished failed and nonmatching jobs" do
    finished = job(1, "BuildInstrumentPerformanceObservationsJob", instrument_id: 4)
    finished.finished_at = Time.current
    failed = job(2, "BuildInstrumentPerformanceObservationsJob", instrument_id: 4)
    no_execution = job(3, "BuildInstrumentPerformanceObservationsJob", instrument_id: 5)
    activity = build_activity([ finished, failed, no_execution ], live_ids: [ 2, 3 ], failed_ids: [ 2 ])

    refute activity.active_job?(class_name: "BuildInstrumentPerformanceObservationsJob") { |args| args[:instrument_id] == 4 }
    refute activity.active_job?(class_name: "OtherJob") { true }
  end

  test "ignores a matching job without a live execution" do
    job = job(4, "BuildInstrumentPerformanceObservationsJob", instrument_id: 4)
    activity = build_activity([ job ], live_ids: [])

    refute activity.active_job?(class_name: "BuildInstrumentPerformanceObservationsJob") { |args| args[:instrument_id] == 4 }
  end

  test "supports the class-level query" do
    activity = build_activity([], live_ids: [])

    with_stubbed_method(MarketData::QueueActivity, :new, -> { activity }) do
      refute MarketData::QueueActivity.active_job?(class_name: "NoSuchJob") { true }
    end
  end

  private

  def job(id, job_class, **arguments)
    Job.new(id, nil, { "job_class" => job_class, "arguments" => [ arguments.stringify_keys ] })
  end

  def build_activity(records, live_ids:, failed_ids: [])
    MarketData::QueueActivity.new(
      job_scope: JobScope.new(records),
      failed_execution: FailedExecution.new(failed_ids),
      execution_classes: [ Execution.new(live_ids) ]
    )
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
