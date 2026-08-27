require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "connects public clients as the configured owner" do
    connect

    assert_equal User.owner, connection.current_user
  end
end
