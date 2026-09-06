require "test_helper"

class BackupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  test "queues a backup and returns to the backup section" do
    with_stubbed_method(Backup::CreationRequest, :call, -> { :queued }) do
      post backups_creation_url
    end

    assert_redirected_to "#{market_data_health_path}#backups"
    follow_redirect!
    assert_response :success
  end

  test "reports a backup creation failure without exposing details" do
    with_stubbed_method(Backup::CreationRequest, :call, -> { raise Backup::Error, "/private/database.sqlite3" }) do
      post backups_creation_url
    end

    assert_redirected_to "#{market_data_health_path}#backups"
    refute_includes flash[:alert], "database.sqlite3"
  end

  test "verifies a signed backup identifier and returns to the backup section" do
    directory = Pathname("/tmp/backup-run")
    verified_directory = nil
    with_stubbed_method(Backup::Locator, :resolve, ->(_identifier) { directory }) do
      with_stubbed_method(Backup::Verifier, :call, ->(directory:) { verified_directory = directory }) do
        post backups_verifications_url, params: { identifier: "signed" }
      end
    end

    assert_redirected_to "#{market_data_health_path}#backups"
    assert_equal directory, verified_directory
    assert_equal "The backup passed its integrity checks.", flash[:notice]
  end

  test "rejects an invalid backup identifier without exposing filesystem details" do
    with_stubbed_method(Backup::Locator, :resolve, ->(_identifier) { raise Backup::Error, "/private/database.sqlite3" }) do
      post backups_verifications_url, params: { identifier: "tampered" }
    end

    assert_redirected_to "#{market_data_health_path}#backups"
    refute_includes flash[:alert], "database.sqlite3"
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
