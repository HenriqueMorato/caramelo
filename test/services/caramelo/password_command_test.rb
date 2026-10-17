require "test_helper"
require "stringio"

class Caramelo::PasswordCommandTest < ActiveSupport::TestCase
  class TerminalInput < StringIO
    def tty?
      true
    end
  end

  class NoechoTerminalInput < TerminalInput
    def noecho
      yield self
    end
  end

  test "prints usage without requiring a terminal for help" do
    output = StringIO.new

    status = Caramelo::PasswordCommand.run([ "--help" ], input: StringIO.new, output:, error: StringIO.new)

    assert_equal 0, status
    assert_includes output.string, "bin/caramelo-password setup"
  end

  test "rejects non-interactive input" do
    error = StringIO.new

    status = Caramelo::PasswordCommand.run([ "setup" ], input: StringIO.new, output: StringIO.new, error:)

    assert_equal 1, status
    assert_includes error.string, "interactive terminal"
  end

  test "rejects an unknown command" do
    error = StringIO.new

    status = Caramelo::PasswordCommand.run(
      [ "unknown" ], input: TerminalInput.new, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "bin/caramelo-password setup"
  end

  test "requires an email for a password change" do
    error = StringIO.new

    status = Caramelo::PasswordCommand.run(
      [ "change" ], input: TerminalInput.new, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "change EMAIL"
  end

  test "rejects extra password change arguments" do
    error = StringIO.new

    status = Caramelo::PasswordCommand.run(
      [ "change", users(:owner).email_address, "extra" ], input: TerminalInput.new, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "Unexpected arguments"
  end

  test "rejects unexpected setup arguments" do
    error = StringIO.new

    status = Caramelo::PasswordCommand.run(
      [ "setup", "extra" ], input: TerminalInput.new, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "Unexpected arguments"
  end

  test "sets the first owner password from the terminal" do
    User.owner.update!(password_configured_at: nil)
    input = terminal_input("Strongpass1!", "Strongpass1!")

    status = Caramelo::PasswordCommand.run([ "setup" ], input:, output: StringIO.new, error: StringIO.new)

    assert_equal 0, status
    assert User.owner.reload.authenticate("Strongpass1!")
  end

  test "reports an invalid first password" do
    User.owner.update!(password_configured_at: nil)
    input = TerminalInput.new("weak\nweak\n")
    error = StringIO.new

    status = Caramelo::PasswordCommand.run([ "setup" ], input:, output: StringIO.new, error:)

    assert_equal 1, status
    assert_includes error.string, "too short"
  end

  test "reports a duplicate setup write" do
    original = Caramelo::PasswordProvisioner.method(:setup_owner)
    Caramelo::PasswordProvisioner.define_singleton_method(:setup_owner) do |**|
      raise ActiveRecord::RecordNotUnique
    end
    error = StringIO.new

    status = Caramelo::PasswordCommand.run(
      [ "setup" ], input: terminal_input("Strongpass1!", "Strongpass1!"), output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "already been taken"
  ensure
    Caramelo::PasswordProvisioner.define_singleton_method(:setup_owner, original) if original
  end

  test "changes a password after prompting for the current password" do
    input = terminal_input("password", "Changedpass1!", "Changedpass1!")

    status = Caramelo::PasswordCommand.run(
      [ "change", users(:owner).email_address ], input:, output: StringIO.new, error: StringIO.new
    )

    assert_equal 0, status
    assert users(:owner).reload.authenticate("Changedpass1!")
  end

  test "does not change a password when the current password is wrong" do
    input = terminal_input("wrong", "Changedpass1!", "Changedpass1!")
    error = StringIO.new

    status = Caramelo::PasswordCommand.run(
      [ "change", users(:owner).email_address ], input:, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "current password"
    assert users(:owner).reload.authenticate("password")
  end

  test "requires explicit confirmation for recovery" do
    input = terminal_input("no", "Recoveredpass1!", "Recoveredpass1!")
    error = StringIO.new

    status = Caramelo::PasswordCommand.run(
      [ "reset", users(:owner).email_address ], input:, output: StringIO.new, error:
    )

    assert_equal 1, status
    assert_includes error.string, "cancelled"
    assert users(:owner).reload.authenticate("password")
  end

  test "resets a forgotten password after explicit confirmation" do
    input = terminal_input("RESET", "Recoveredpass1!", "Recoveredpass1!")

    status = Caramelo::PasswordCommand.run(
      [ "reset", users(:owner).email_address ], input:, output: StringIO.new, error: StringIO.new
    )

    assert_equal 0, status
    assert users(:owner).reload.authenticate("Recoveredpass1!")
  end

  test "supports password prompts that hide terminal input" do
    input = NoechoTerminalInput.new("Strongpass1!\nStrongpass1!\n")
    prompts = Caramelo::TerminalPrompts.new(input:, output: StringIO.new)

    assert_equal [ "Strongpass1!", "Strongpass1!" ], prompts.password_pair
  end

  private

    def terminal_input(*values)
      TerminalInput.new(values.join("\n") + "\n")
    end
end
