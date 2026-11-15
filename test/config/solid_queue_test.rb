require "test_helper"
require "timeout"

class SolidQueueTest < ActiveSupport::TestCase
  ProcessExit = Class.new(StandardError)

  test "keeps the worker alive after a failed execution" do
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      reported = Queue.new
      reporter = Rails.error
      reporter.define_singleton_method(:report) { |exception, **| reported << exception }
      SolidQueue.supervisor = true
      SolidQueue.on_thread_error = Rails.application.config.solid_queue.on_thread_error
      pool = SolidQueue::ThreadPool.new(1)

      failing = Object.new
      failing.define_singleton_method(:perform) { raise "job failed" }
      succeeding = Object.new
      succeeding.define_singleton_method(:perform) { writer.write("success") }

      pool.post(failing)
      Timeout.timeout(5) { reported.pop }
      Timeout.timeout(5) { sleep 0.01 until pool.idle? }
      pool.post(succeeding)
      Timeout.timeout(5) { pool.shutdown; pool.wait_for_termination }
      exit!(0)
    rescue Exception => error
      writer.write("error:#{error.class}:#{error.message}")
      exit!(1)
    ensure
      writer.close
    end
    writer.close

    _, status = Timeout.timeout(10) { Process.wait2(pid) }
    output = reader.read
    reader.close

    assert_predicate status, :success?, "worker subprocess failed: #{output.inspect}"
    assert_equal "success", output
  rescue Timeout::Error
    Process.kill("KILL", pid)
    Process.wait(pid)
    flunk "queue worker subprocess did not finish"
  end

  test "restarts a supervisor worker for an internal queue error" do
    error = ActiveRecord::StatementInvalid.new("database is locked")
    error.set_backtrace([ "/workspaces/caramelo/vendor/bundle/gems/solid_queue-1.7.0/app/models/solid_queue/job.rb:1" ])
    reported = []

    with_stubbed_method(Rails.error, :report, ->(exception, **) { reported << exception }) do
      with_stubbed_method(SolidQueue, :supervisor?, -> { true }) do
        with_stubbed_method(Process, :exit!, ->(status) { raise ProcessExit, status }) do
          assert_raises(ProcessExit) do
            Rails.application.config.solid_queue.on_thread_error.call(error)
          end
        end
      end
    end

    assert_equal [ error ], reported
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
