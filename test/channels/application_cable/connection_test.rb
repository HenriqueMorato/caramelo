require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "connects public clients as the configured owner" do
    connect

    assert_equal User.owner, connection.current_user
  end

  test "connects authenticated clients as their session user" do
    user = users(:one)
    session = user.sessions.create!
    cookies.signed[:session_id] = session.id

    connect

    assert_equal user, connection.current_user
  end
end
