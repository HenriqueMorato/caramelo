require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "rejects clients without a session" do
    assert_reject_connection { connect }
  end

  test "connects authenticated clients as their session user" do
    user = users(:owner)
    session = user.sessions.create!
    cookies.signed[:session_id] = session.id

    connect

    assert_equal user, connection.current_user
  end

  test "connects another account only in multi-account mode" do
    previous = Rails.application.config.x.caramelo.account_mode
    Rails.application.config.x.caramelo.account_mode = "multi"
    user = users(:one)
    cookies.signed[:session_id] = user.sessions.create!.id

    connect

    assert_equal user, connection.current_user
  ensure
    Rails.application.config.x.caramelo.account_mode = previous
  end

  test "rejects another account after switching back to single-account mode" do
    user = users(:one)
    cookies.signed[:session_id] = user.sessions.create!.id

    assert_reject_connection { connect }
  end

  test "rejects a session whose password has not been configured" do
    previous = Rails.application.config.x.caramelo.account_mode
    Rails.application.config.x.caramelo.account_mode = "multi"
    user = users(:one)
    user.update!(password_configured_at: nil)
    cookies.signed[:session_id] = user.sessions.create!.id

    assert_reject_connection { connect }
  ensure
    Rails.application.config.x.caramelo.account_mode = previous
  end
end
