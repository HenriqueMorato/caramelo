require "test_helper"

class MarketData::HealthReportPresenterTest < ActiveSupport::TestCase
  PreviewFactory = Struct.new(:preview) do
    def create(target:)
      preview
    end
  end

  Entry = Struct.new(:healthy, :resettable, :provider, :record_id) do
    def healthy? = healthy
    def quote_reset_needed? = resettable
    def target = Struct.new(:provider, :record_id).new(provider, record_id)
  end

  test "filters entries and exposes reset previews" do
    resettable = Entry.new(false, true, "yahoo_finance", 1)
    healthy = Entry.new(true, false, nil, 2)
    report = report_with(entries: [ resettable, healthy ], issues: [ :issue ])
    preview = Object.new

    presenter = MarketData::HealthReportPresenter.new(
      report:, status_filter: "attention", preview_factory: PreviewFactory.new(preview)
    )

    assert_equal [ resettable ], presenter.entries
    assert_same preview, presenter.reset_preview_for(resettable)
    assert_equal 1, presenter.issue_count
    refute presenter.healthy?
  end

  test "falls back to all entries for an unknown filter" do
    entries = [ Entry.new(true, false, nil, 1) ]
    presenter = MarketData::HealthReportPresenter.new(report: report_with(entries:, issues: []), status_filter: "other")

    assert_equal entries, presenter.entries
    assert presenter.healthy?
    assert_nil presenter.reset_preview_for(entries.first)
  end

  private

  def report_with(entries:, issues:)
    Struct.new(:entries, :issues) do
      def healthy? = issues.empty?
    end.new(entries, issues)
  end
end
