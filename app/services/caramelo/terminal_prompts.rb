module Caramelo
  class TerminalPrompts
    def initialize(input:, output:)
      @input = input
      @output = output
    end

    def password_pair
      password = secret("Password: ")
      confirmation = secret("Confirm password: ")
      [ password, confirmation ]
    end

    def current_password
      secret("Current password: ")
    end

    def confirm_reset
      @output.print "This resets the password without checking the current one. Type RESET to continue: "
      @input.gets.to_s.chomp == "RESET"
    end

    private

      def secret(prompt)
        @output.print prompt
        value = if @input.respond_to?(:noecho)
          @input.noecho(&:gets)
        else
          @input.gets
        end
        @output.puts
        value.to_s.chomp
      end
  end
end
