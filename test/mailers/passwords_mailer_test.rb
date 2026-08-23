require "test_helper"

class PasswordsMailerTest < ActionMailer::TestCase
  test "renders localized reset instructions in html and text" do
    mail = PasswordsMailer.reset(users(:owner))

    assert_equal "Reset your password", mail.subject
    assert_equal [ users(:owner).email_address ], mail.to
    assert_match "this password reset page", mail.html_part.body.decoded
    assert_match "This link will expire", mail.html_part.body.decoded
    assert_match "This link will expire", mail.text_part.body.decoded
  end
end
