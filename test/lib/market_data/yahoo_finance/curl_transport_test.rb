require "test_helper"

class MarketData::YahooFinance::CurlTransportTest < ActiveSupport::TestCase
  ProcessStatus = Data.define(:success, :exitstatus) do
    def success?
      success
    end
  end

  test "returns the response without invoking a shell" do
    captured_arguments = nil
    runner = lambda do |*arguments|
      captured_arguments = arguments
      File.binwrite(argument_value(arguments, "--dump-header"), "HTTP/2 200\r\nRetry-After: 60\r\n\r\n")
      File.binwrite(argument_value(arguments, "--output"), "response body")
      [ "200", "", ProcessStatus.new(success: true, exitstatus: 0) ]
    end
    transport = build_transport(command_runner: runner)

    response = transport.get(URI("https://query1.finance.yahoo.com/v8/finance/chart/PETR4.SA?range=1d"))

    assert_equal 200, response.status
    assert_equal "response body", response.body
    assert_equal({ "retry-after" => "60" }, response.headers)
    assert_equal "curl_chrome146", captured_arguments.first
    assert_equal "https://query1.finance.yahoo.com/v8/finance/chart/PETR4.SA?range=1d", captured_arguments.last
  end

  test "rejects hosts and schemes outside the fixed Yahoo endpoint" do
    transport = build_transport(command_runner: ->(*) { flunk "runner should not be called" })

    assert_raises(MarketData::YahooFinance::TransportError) do
      transport.get(URI("https://example.com/"))
    end
    assert_raises(MarketData::YahooFinance::TransportError) do
      transport.get(URI("http://query1.finance.yahoo.com/"))
    end
  end

  test "classifies executable timeout and process failures" do
    assert_raises(MarketData::YahooFinance::ExecutableNotFound) do
      build_transport(command_runner: ->(*) { raise Errno::ENOENT, "missing" }).get(valid_uri)
    end

    assert_raises(MarketData::YahooFinance::RequestTimeout) do
      failing_transport(exitstatus: 28, error: "operation timed out").get(valid_uri)
    end

    error = assert_raises(MarketData::YahooFinance::TransportError) do
      failing_transport(exitstatus: 2, error: "bad option").get(valid_uri)
    end
    assert_equal "bad option", error.message
  end

  test "requires a configured executable and positive timeout" do
    assert_raises(MarketData::YahooFinance::ConfigurationError) do
      build_transport(executable: "")
    end
    assert_raises(MarketData::YahooFinance::ConfigurationError) do
      build_transport(timeout: 0)
    end
  end

  private

  def build_transport(executable: "curl_chrome146", timeout: 15, command_runner: ->(*) { })
    MarketData::YahooFinance::CurlTransport.new(executable:, timeout:, command_runner:)
  end

  def failing_transport(exitstatus:, error:)
    build_transport(
      command_runner: lambda do |*arguments|
        File.binwrite(argument_value(arguments, "--dump-header"), "")
        File.binwrite(argument_value(arguments, "--output"), "")
        [ "", error, ProcessStatus.new(success: false, exitstatus:) ]
      end
    )
  end

  def valid_uri
    URI("https://query1.finance.yahoo.com/v8/finance/chart/PETR4.SA")
  end

  def argument_value(arguments, option)
    arguments.fetch(arguments.index(option) + 1)
  end
end
