require "test_helper"

class InstitutionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @institution = institutions(:owner_xp)
  end

  test "lists only the configured owner's institutions" do
    get institutions_url

    assert_response :success
    assert_select "h1", "Institutions"
    assert_select "h2", text: @institution.name
    assert_select "h2", text: institutions(:other_owner).name, count: 0
  end

  test "shows an owner institution" do
    get institution_url(@institution)

    assert_response :success
    assert_select "h1", @institution.name
  end

  test "shows the new institution form" do
    get new_institution_url

    assert_response :success
    assert_select "h1", /institution/i
    assert_select "form[action=?]", institutions_path
  end

  test "does not expose another owner's institution" do
    get institution_url(institutions(:other_owner))

    assert_response :not_found
  end

  test "creates an institution for the configured owner" do
    assert_difference("User.owner.institutions.count") do
      post institutions_url, params: {
        institution: {
          name: "  BTG   Pactual  ",
          notes: "Retirement investments",
          user_id: users(:one).id
        }
      }
    end

    institution = Institution.order(:id).last
    assert_redirected_to institution_url(institution)
    assert_equal User.owner, institution.user
    assert_equal "BTG Pactual", institution.name
  end

  test "renders validation errors when creation fails" do
    assert_no_difference("Institution.count") do
      post institutions_url, params: { institution: { name: "" } }
    end

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Name can't be blank/
  end

  test "updates an institution" do
    patch institution_url(@institution), params: {
      institution: { name: "XP", notes: "Updated notes", active: false }
    }

    assert_redirected_to institution_url(@institution)
    assert_equal "XP", @institution.reload.name
    assert_equal "Updated notes", @institution.notes
    assert_not @institution.reload.active?

    patch institution_url(@institution), params: { institution: { active: true } }

    assert_redirected_to institution_url(@institution)
    assert_predicate @institution.reload, :active?
  end

  test "renders validation errors when update fails" do
    patch institution_url(@institution), params: { institution: { name: "" } }

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Name can't be blank/
    assert_not @institution.reload.name.blank?
  end

  test "deletes an unused institution" do
    assert_difference("Institution.count", -1) do
      delete institution_url(@institution)
    end

    assert_redirected_to institutions_url
  end

  test "does not delete an institution referenced by a trade" do
    institution = institutions(:owner_inactive)

    assert_no_difference("Institution.count") do
      delete institution_url(institution)
    end

    assert_redirected_to institution_url(institution)
    assert_equal "Cannot delete record because dependent trades exist", flash[:alert]
  end
end
