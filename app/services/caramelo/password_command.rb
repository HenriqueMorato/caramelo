module Caramelo
  class PasswordCommand
    USAGE = <<~TEXT.freeze
      Usage:
        bin/caramelo-password setup
        bin/caramelo-password change EMAIL
        bin/caramelo-password reset EMAIL
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

      case @arguments.shift
      when "setup"
        setup_owner
      when "change"
        change_password
      when "reset"
        reset_password
      else
        failure(USAGE)
      end
    rescue ActiveRecord::RecordInvalid => error
      failure(error.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotUnique
      failure("Email address has already been taken.")
    rescue Caramelo::PasswordProvisioner::NotReady, Caramelo::PasswordProvisioner::InvalidCurrentPassword => error
      failure(error.message.presence || "The current password is incorrect.")
    end

    private

      def setup_owner
        require_no_arguments!
        password, confirmation = prompts.password_pair
        user = PasswordProvisioner.setup_owner(password:, password_confirmation: confirmation)
        success("Configured password for #{user.email_address}.")
      end

      def change_password
        user = find_user!(usage: "Usage: bin/caramelo-password change EMAIL")
        current_password = prompts.current_password
        password, confirmation = prompts.password_pair
        PasswordProvisioner.change(
          user:, current_password:, password:, password_confirmation: confirmation
        )
        success("Changed password for #{user.email_address}.")
      end

      def reset_password
        user = find_user!(usage: "Usage: bin/caramelo-password reset EMAIL")
        return failure("Password reset cancelled.") unless prompts.confirm_reset

        password, confirmation = prompts.password_pair
        PasswordProvisioner.reset(user:, password:, password_confirmation: confirmation)
        success("Reset password for #{user.email_address}.")
      end

      def find_user!(usage:)
        email_address = @arguments.shift.to_s.strip.downcase
        raise Caramelo::PasswordProvisioner::NotReady, usage if email_address.empty?
        raise Caramelo::PasswordProvisioner::NotReady, "Unexpected arguments." if @arguments.any?

        User.find_by(email_address:) || raise(Caramelo::PasswordProvisioner::NotReady, "Account not found.")
      end

      def require_no_arguments!
        return if @arguments.empty?

        raise Caramelo::PasswordProvisioner::NotReady, "Unexpected arguments."
      end

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
