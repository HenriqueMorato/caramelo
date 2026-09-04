require "test_helper"

class MarketData::RecoveriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  test "queues a supported target and redirects to data health" do
    instrument = instruments(:voo_arcx)
    attributes = { kind: "current_price", record_id: instrument.id }
    target = nil

    with_stubbed_method(MarketData::Recovery, :call, ->(**arguments) {
      target = arguments.fetch(:target)
      MarketData::Recovery::Result.new(
        status: :queued, target:, batch_scope: "batch", batch_run_id: "run"
      )
    }) do
      post market_data_recoveries_path, params: { target: attributes }
    end

    assert_equal :current_price, target.kind
    assert_redirected_to market_data_health_path
    assert_equal "Market data recovery started.", flash[:notice]
  end

  test "returns too many requests when target recovery is throttled" do
    with_stubbed_method(MarketData::Recovery, :call, ->(**arguments) {
      MarketData::Recovery::Result.new(
        status: :throttled, target: arguments.fetch(:target), batch_scope: "batch", batch_run_id: "run"
      )
    }) do
      post market_data_recoveries_path, params: {
        target: { kind: "current_price", record_id: instruments(:voo_arcx).id }
      }
    end

    assert_response :too_many_requests
  end

  test "rejects malformed or out-of-scope targets" do
    post market_data_recoveries_path, params: {
      target: { kind: "current_price", record_id: instruments(:petr4_bvmf).id }
    }

    assert_response :unprocessable_entity
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
