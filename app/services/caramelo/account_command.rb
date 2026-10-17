module Caramelo
  class AccountCommand
    USAGE = <<~TEXT.freeze
      Usage:
        bin/caramelo-account create EMAIL
    TEXT

    def self.run(arguments, input: $stdin, output: $stdout, error: $stderr)
      new(arguments, input:, output:, error:).run
    end

    def initialize(arguments, input:, output:, error:)
      @arguments = arguments.dup
      @input = input
      @output = output
      @error = error
    end

    def run
      return print_usage if @arguments.empty? || @arguments.first == "--help"
      return failure("Run this command from an interactive terminal.") unless @input.tty?
      return failure(USAGE) unless @arguments.shift == "create"

      email_address = @arguments.shift.to_s.strip
      return failure("Usage: bin/caramelo-account create EMAIL") if email_address.empty? || @arguments.any?

      password, confirmation = prompts.password_pair
      user = AccountProvisioner.call(email_address:, password:, password_confirmation: confirmation)
      success("Created account for #{user.email_address}.")
    rescue ActiveRecord::RecordInvalid => error
      failure(error.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotUnique
      failure("Email address has already been taken.")
    rescue Caramelo::AccountProvisioner::NotReady => error
      failure(error.message)
    end

    private

      def prompts
        @prompts ||= TerminalPrompts.new(input: @input, output: @output)
      end

      def print_usage
        @output.write(USAGE)
        0
      end

      def success(message)
        @output.puts message
        0
      end

      def failure(message)
        @error.puts message
        1
      end
  end
end
