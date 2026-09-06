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

  test "returns unprocessable entity when target recovery is unsupported" do
    with_stubbed_method(MarketData::Recovery, :call, ->(**arguments) {
      MarketData::Recovery::Result.new(
        status: :unsupported, target: arguments.fetch(:target), batch_scope: nil, batch_run_id: nil
      )
    }) do
      post market_data_recoveries_path, params: {
        target: { kind: "current_price", record_id: instruments(:voo_arcx).id }
      }
    end

    assert_response :unprocessable_entity
  end

  test "returns conflict when quote reset is already active" do
    result = MarketData::Reset::Result.new(
      status: :busy,
      target: MarketData::Target.new(kind: :current_price, record_id: instruments(:voo_arcx).id)
    )

    with_stubbed_method(MarketData::Reset, :call, ->(**) { result }) do
      delete market_data_recovery_path(instruments(:voo_arcx).id), params: {
        target: { kind: "current_price", record_id: instruments(:voo_arcx).id },
        preview_token: reset_preview_token
      }
    end

    assert_response :conflict
  end

  test "returns unprocessable entity when quote reset is unsupported" do
    result = MarketData::Reset::Result.new(
      status: :unsupported,
      target: MarketData::Target.new(kind: :current_price, record_id: instruments(:voo_arcx).id)
    )

    with_stubbed_method(MarketData::Reset, :call, ->(**) { result }) do
      delete market_data_recovery_path(instruments(:voo_arcx).id), params: {
        target: { kind: "current_price", record_id: instruments(:voo_arcx).id },
        preview_token: reset_preview_token
      }
    end

    assert_response :unprocessable_entity
  end

  test "rejects malformed reset targets" do
    delete market_data_recovery_path(instruments(:voo_arcx).id), params: {
      target: { kind: "unknown", record_id: instruments(:voo_arcx).id }
    }

    assert_response :unprocessable_entity
  end

  test "rejects malformed or out-of-scope targets" do
    post market_data_recoveries_path, params: {
      target: { kind: "current_price", record_id: instruments(:petr4_bvmf).id }
    }

    assert_response :unprocessable_entity
  end

  test "rejects a future or reversed recovery range" do
    post market_data_recoveries_path, params: {
      from: Date.current.tomorrow.iso8601,
      to: Date.current.iso8601,
      target: { kind: "current_price", record_id: instruments(:voo_arcx).id }
    }

    assert_response :unprocessable_entity
  end

  test "passes a valid recovery range to the service" do
    range = Date.current - 3.days..Date.current - 1.day
    captured = nil

    with_stubbed_method(MarketData::Recovery, :call, ->(**arguments) {
      captured = arguments.fetch(:range)
      MarketData::Recovery::Result.new(
        status: :queued, target: arguments.fetch(:target), batch_scope: "batch", batch_run_id: "run"
      )
    }) do
      post market_data_recoveries_path, params: {
        from: range.begin.iso8601, to: range.end.iso8601,
        target: { kind: "current_price", record_id: instruments(:voo_arcx).id }
      }
    end

    assert_equal range, captured
    assert_redirected_to market_data_health_path
  end

  test "queues a replacement for a replaceable quote" do
    result = MarketData::Reset::Result.new(
      status: :queued,
      target: MarketData::Target.new(kind: :current_price, record_id: instruments(:voo_arcx).id)
    )

    with_stubbed_method(MarketData::Reset, :call, ->(**) { result }) do
      delete market_data_recovery_path(instruments(:voo_arcx).id), params: {
        target: { kind: "current_price", record_id: instruments(:voo_arcx).id },
        preview_token: reset_preview_token
      }
    end

    assert_redirected_to market_data_health_path
    assert_equal "Quote refresh started.", flash[:notice]
  end

  private

  def reset_preview_token
    MarketData::ResetPreview.create(
      target: MarketData::Target.new(kind: :current_price, record_id: instruments(:voo_arcx).id,
        provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier), owner: users(:owner)
    ).token
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
