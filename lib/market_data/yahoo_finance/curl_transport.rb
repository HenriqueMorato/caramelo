module MarketData
  module YahooFinance
    class CurlTransport
      ALLOWED_HOST = "query1.finance.yahoo.com"
      DEFAULT_CONNECT_TIMEOUT = 5
      def self.from_configuration(configuration)
        new(
          executable: configuration.executable,
          timeout: configuration.timeout
        )
      end

      def initialize(executable:, timeout:, command_runner: Open3.method(:capture3))
        @executable = executable.to_s
        @timeout = Integer(timeout)
        @command_runner = command_runner

        raise ConfigurationError, "executable is required" if @executable.empty?
        raise ConfigurationError, "timeout must be positive" unless @timeout.positive?
      rescue ArgumentError, TypeError => error
        raise ConfigurationError, error.message
      end

      def get(uri)
        validate_uri!(uri)

        Tempfile.create("yahoo-finance-headers") do |headers_file|
          Tempfile.create("yahoo-finance-body") do |body_file|
            stdout, stderr, process_status = command_runner.call(
              *command(uri:, headers_file:, body_file:)
            )
            validate_process!(process_status, stderr)

            Response.new(
              status: Integer(stdout.strip),
              body: File.binread(body_file.path),
              headers: parse_headers(File.binread(headers_file.path))
            )
          end
        end
      rescue Errno::ENOENT => error
        raise ExecutableNotFound, error.message
      rescue ArgumentError => error
        raise TransportError, "invalid HTTP status: #{error.message}"
      end

      private

      attr_reader :executable, :timeout, :command_runner

      def validate_uri!(uri)
        valid = uri.is_a?(URI::HTTPS) && uri.host == ALLOWED_HOST && uri.port == 443 && uri.userinfo.nil?
        raise TransportError, "unsupported Yahoo Finance URI" unless valid
      end

      def command(uri:, headers_file:, body_file:)
        [
          executable,
          "--silent",
          "--show-error",
          "--proto", "=https",
          "--connect-timeout", DEFAULT_CONNECT_TIMEOUT.to_s,
          "--max-time", timeout.to_s,
          "--dump-header", headers_file.path,
          "--output", body_file.path,
          "--write-out", "%{http_code}",
          uri.to_s
        ]
      end

      def validate_process!(process_status, stderr)
        return if process_status.success?

        message = stderr.to_s.strip
        message = "curl-impersonate exited with status #{process_status.exitstatus}" if message.empty?

        if process_status.exitstatus == 28
          raise RequestTimeout, message
        else
          raise TransportError, message
        end
      end

      def parse_headers(raw_headers)
        raw_headers.each_line.filter_map do |line|
          name, value = line.split(":", 2)
          next unless value

          [ name.strip.downcase, value.strip ]
        end.to_h.freeze
      end
    end
  end
end
