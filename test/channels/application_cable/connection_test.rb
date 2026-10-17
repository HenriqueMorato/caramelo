require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "rejects clients without a session" do
    assert_reject_connection { connect }
  end

  test "connects public single-account clients as the owner" do
    previous = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.authentication_mode = "public"

    connect

    assert_equal User.owner, connection.current_user
  ensure
    Rails.application.config.x.caramelo.authentication_mode = previous
  end

  test "keeps multi-account clients protected when public authentication is configured" do
    previous_mode = Rails.application.config.x.caramelo.account_mode
    previous_authentication = Rails.application.config.x.caramelo.authentication_mode
    Rails.application.config.x.caramelo.account_mode = "multi"
    Rails.application.config.x.caramelo.authentication_mode = "public"

    assert_reject_connection { connect }
  ensure
    Rails.application.config.x.caramelo.account_mode = previous_mode
    Rails.application.config.x.caramelo.authentication_mode = previous_authentication
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

  test "disconnects cable connections for a user" do
    calls = []
    user = users(:one)
    remote_connections = Object.new
    remote_connections.define_singleton_method(:where) do |conditions|
      calls << conditions
      self
    end
    remote_connections.define_singleton_method(:disconnect) { calls << :disconnect }

    with_stubbed_method(ActionCable.server, :remote_connections, -> { remote_connections }) do
      ApplicationCable::Connection.disconnect_user(user)
    end

    assert_equal [ { current_user: user }, :disconnect ], calls
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
