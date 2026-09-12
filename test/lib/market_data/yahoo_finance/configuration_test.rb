require "test_helper"

class MarketData::YahooFinance::ConfigurationTest < ActiveSupport::TestCase
  test "wires Yahoo market and FX defaults" do
    assert_equal "yahoo_finance", MarketData::YahooFinance::MARKET_CONFIGURATION.identifier
    assert_equal 15, MarketData::YahooFinance::MARKET_CONFIGURATION.timeout
    assert_equal "yahoo_finance_fx", MarketData::YahooFinance::FX_CONFIGURATION.identifier
    assert_equal 10, MarketData::YahooFinance::FX_CONFIGURATION.timeout
  end

  test "uses the default executable unless it is overridden" do
    configuration = configuration_for
    previous = ENV["YAHOO_FINANCE_HTTP_EXECUTABLE"]
    ENV.delete("YAHOO_FINANCE_HTTP_EXECUTABLE")

    assert_equal "curl_chrome146", configuration.executable

    ENV["YAHOO_FINANCE_HTTP_EXECUTABLE"] = "custom-curl"
    assert_equal "custom-curl", configuration.executable
  ensure
    ENV["YAHOO_FINANCE_HTTP_EXECUTABLE"] = previous
  end

  test "uses the default and configured provider intervals" do
    configuration = configuration_for
    previous = ENV["CARAMELO_TEST_PROVIDER_INTERVAL"]
    ENV.delete("CARAMELO_TEST_PROVIDER_INTERVAL")

    assert_equal 1.second, configuration.interval

    ENV["CARAMELO_TEST_PROVIDER_INTERVAL"] = "2.5"

    assert_equal 2.5.seconds, configuration.interval
  ensure
    ENV["CARAMELO_TEST_PROVIDER_INTERVAL"] = previous
  end

  test "rejects invalid provider intervals" do
    configuration = configuration_for
    previous = ENV["CARAMELO_TEST_PROVIDER_INTERVAL"]

    %w[not-a-number 0].each do |value|
      ENV["CARAMELO_TEST_PROVIDER_INTERVAL"] = value

      assert_raises(ArgumentError) { configuration.interval }
    end
  ensure
    ENV["CARAMELO_TEST_PROVIDER_INTERVAL"] = previous
  end

  private

  def configuration_for
    MarketData::YahooFinance::Configuration.new(
      identifier: "test_provider", timeout: 5,
      interval_environment_variable: "CARAMELO_TEST_PROVIDER_INTERVAL", default_interval: 1.second
    )
  end
end
