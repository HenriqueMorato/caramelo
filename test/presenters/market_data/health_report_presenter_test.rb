require "test_helper"

class MarketData::HealthReportPresenterTest < ActiveSupport::TestCase
  PreviewFactory = Struct.new(:preview, :calls) do
    def create(target:, range:)
      calls << [ target, range ]
      preview
    end
  end

  Target = Struct.new(:scope)
  Entry = Struct.new(:healthy, :resettable, :scope, :covered_range, :missing_range) do
    def healthy? = healthy
    def resettable? = resettable
    def target = Target.new(scope)
  end

  test "filters entries and exposes reset previews" do
    range = Date.new(2026, 9, 1)..Date.new(2026, 9, 2)
    resettable = Entry.new(false, true, "source:1", range, nil)
    healthy = Entry.new(true, false, "source:2", nil, nil)
    report = report_with(entries: [ resettable, healthy ], issues: [ :issue ])
    preview = Object.new
    factory = PreviewFactory.new(preview, [])

    presenter = MarketData::HealthReportPresenter.new(
      report:, status_filter: "attention", preview_factory: factory
    )

    assert_equal [ resettable ], presenter.entries
    assert_same preview, presenter.reset_preview_for(resettable)
    assert_equal [ [ resettable.target, range ] ], factory.calls
    assert_equal 1, presenter.issue_count
    refute presenter.healthy?
  end

  test "falls back to all entries for an unknown filter" do
    entries = [ Entry.new(true, false, "source:1", nil, nil) ]
    presenter = MarketData::HealthReportPresenter.new(report: report_with(entries:, issues: []), status_filter: "other")

    assert_equal entries, presenter.entries
    assert presenter.healthy?
    assert_nil presenter.reset_preview_for(entries.first)
  end

  test "presents status with a label and semantic tone" do
    presenter = MarketData::HealthReportPresenter.new(report: report_with(entries: [], issues: []))
    healthy = Struct.new(:status, :severity) do
      def healthy? = status == :healthy
    end.new(:healthy, nil)
    failed = Struct.new(:status, :severity) do
      def healthy? = false
    end.new(:failed, :error)

    assert_equal "Healthy", presenter.status_label(healthy)
    assert_equal "text-leaf", presenter.status_class(healthy)
    assert_equal "Failed", presenter.status_label(failed)
    assert_equal "text-guava", presenter.status_class(failed)
  end

  private

  def report_with(entries:, issues:)
    Struct.new(:entries, :issues) do
      def healthy? = issues.empty?
    end.new(entries, issues)
  end
end
