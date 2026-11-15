require "test_helper"

class RecoverStaleMarketDataJobTest < ActiveJob::TestCase
  test "runs both stale recovery passes and broadcasts when work is recovered" do
    performance_result = Performance::StaleRefreshRecovery::Result.new(recovered_count: 1, changed_count: 1)
    scan_result = CorporateActionImports::StaleScanRecovery::Result.new(recovered_count: 2, changed_count: 2)
    broadcasts = 0

    with_stubbed_method(Performance::StaleRefreshRecovery, :call, -> { performance_result }) do
      with_stubbed_method(CorporateActionImports::StaleScanRecovery, :call, -> { scan_result }) do
        with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { broadcasts += 1 }) do
          assert_equal 3, RecoverStaleMarketDataJob.perform_now
        end
      end
    end

    assert_equal 1, broadcasts
  end

  test "does not broadcast when there is nothing to recover" do
    performance_result = Performance::StaleRefreshRecovery::Result.new(recovered_count: 0, changed_count: 0)
    scan_result = CorporateActionImports::StaleScanRecovery::Result.new(recovered_count: 0, changed_count: 0)
    broadcasts = 0

    with_stubbed_method(Performance::StaleRefreshRecovery, :call, -> { performance_result }) do
      with_stubbed_method(CorporateActionImports::StaleScanRecovery, :call, -> { scan_result }) do
        with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { broadcasts += 1 }) do
          assert_equal 0, RecoverStaleMarketDataJob.perform_now
        end
      end
    end

    assert_equal 0, broadcasts
  end

  test "keeps recovery successful when health broadcasting fails" do
    performance_result = Performance::StaleRefreshRecovery::Result.new(recovered_count: 1, changed_count: 1)
    scan_result = CorporateActionImports::StaleScanRecovery::Result.new(recovered_count: 0, changed_count: 0)
    reported = []

    with_stubbed_method(Performance::StaleRefreshRecovery, :call, -> { performance_result }) do
      with_stubbed_method(CorporateActionImports::StaleScanRecovery, :call, -> { scan_result }) do
        with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { raise "broadcast unavailable" }) do
          with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
            assert_equal 1, RecoverStaleMarketDataJob.perform_now
          end
        end
      end
    end

    assert_equal "broadcast unavailable", reported.sole.message
  end

  test "broadcasts when a stale target changes to failed" do
    performance_result = Performance::StaleRefreshRecovery::Result.new(recovered_count: 0, changed_count: 1)
    scan_result = CorporateActionImports::StaleScanRecovery::Result.new(recovered_count: 0, changed_count: 0)
    broadcasts = 0

    with_stubbed_method(Performance::StaleRefreshRecovery, :call, -> { performance_result }) do
      with_stubbed_method(CorporateActionImports::StaleScanRecovery, :call, -> { scan_result }) do
        with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { broadcasts += 1 }) do
          assert_equal 0, RecoverStaleMarketDataJob.perform_now
        end
      end
    end

    assert_equal 1, broadcasts
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
