require "test_helper"
require "stringio"

class Caramelo::AccountCommandTest < ActiveSupport::TestCase
  class TerminalInput < StringIO
    def tty?
      true
    end
  end

  setup do
    @previous_mode = Rails.application.config.x.caramelo.account_mode
    Rails.application.config.x.caramelo.account_mode = "multi"
  end

  teardown do
    Rails.application.config.x.caramelo.account_mode = @previous_mode
  end

  test "prints usage without requiring a terminal for help" do
    output = StringIO.new

    status = Caramelo::AccountCommand.run([ "--help" ], input: StringIO.new, output:, error: StringIO.new)

    assert_equal 0, status
    assert_includes output.string, "bin/caramelo-account create EMAIL"
  end

  test "rejects non-interactive account creation" do
    error = StringIO.new

    status = Caramelo::AccountCommand.run(
      [ "create", "new-person@example.com" ], input: StringIO.new, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "interactive terminal"
  end

  test "rejects an unknown account command" do
    error = StringIO.new

    status = Caramelo::AccountCommand.run(
      [ "unknown" ], input: TerminalInput.new, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "bin/caramelo-account create EMAIL"
  end

  test "rejects extra account arguments" do
    error = StringIO.new

    status = Caramelo::AccountCommand.run(
      [ "create", "new-person@example.com", "extra" ], input: TerminalInput.new, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "Usage: bin/caramelo-account create EMAIL"
  end

  test "creates an account from the terminal" do
    input = TerminalInput.new("Strongpass1!\nStrongpass1!\n")
    email = "command-account@example.com"

    assert_difference("User.count") do
      status = Caramelo::AccountCommand.run(
        [ "create", email ], input:, output: StringIO.new, error: StringIO.new
      )
      assert_equal 0, status
    end

    assert User.find_by!(email_address: email).authenticate("Strongpass1!")
  ensure
    User.find_by(email_address: email)&.destroy!
  end

  test "reports an invalid password" do
    input = TerminalInput.new("weak\nweak\n")
    error = StringIO.new

    status = Caramelo::AccountCommand.run(
      [ "create", "invalid-command-account@example.com" ], input:, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "too short"
  end

  test "reports a duplicate email" do
    input = TerminalInput.new("Strongpass1!\nStrongpass1!\n")
    error = StringIO.new

    status = Caramelo::AccountCommand.run(
      [ "create", users(:owner).email_address ], input:, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "already been taken"
  end

  test "reports a concurrent duplicate email" do
    original = Caramelo::AccountProvisioner.method(:call)
    Caramelo::AccountProvisioner.define_singleton_method(:call) do |**|
      raise ActiveRecord::RecordNotUnique
    end
    input = TerminalInput.new("Strongpass1!\nStrongpass1!\n")
    error = StringIO.new

    status = Caramelo::AccountCommand.run(
      [ "create", "concurrent-account@example.com" ], input:, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "already been taken"
  ensure
    Caramelo::AccountProvisioner.define_singleton_method(:call, original) if original
  end

  test "requires multi-account mode" do
    Rails.application.config.x.caramelo.account_mode = "single"
    input = TerminalInput.new("Strongpass1!\nStrongpass1!\n")
    error = StringIO.new

    status = Caramelo::AccountCommand.run(
      [ "create", "single-mode-account@example.com" ], input:, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "CARAMELO_ACCOUNT_MODE=multi"
  end
end
