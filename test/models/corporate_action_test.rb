require "test_helper"

class CorporateActionTest < ActiveSupport::TestCase
  test "belongs to its owner and instrument with optional context" do
    action = build_action

    assert_equal users(:owner), action.user
    assert_equal instruments(:petr4_bvmf), action.instrument
    assert_equal institutions(:owner_xp), action.institution
    assert_predicate action, :valid?

    action.institution = nil
    assert_predicate action, :valid?
  end

  test "supports dividend and JCP without inferring tax" do
    assert_predicate build_action(kind: :dividend, withholding_tax_cents: 0, net_amount_cents: 1_000), :valid?
    assert_predicate build_action(kind: :jcp, withholding_tax_cents: 137, net_amount_cents: 863), :valid?

    invalid = build_action(kind: :interest)

    assert_predicate invalid, :invalid?
    assert_includes invalid.errors[:kind], "is not included in the list"
  end

  test "only permits JCP for BRL instruments" do
    action = build_action(
      instrument: instruments(:voo_arcx), institution: nil, currency: "USD", kind: :jcp
    )

    assert_predicate action, :invalid?
    assert_includes action.errors[:kind], "JCP is only available for BRL instruments"
  end

  test "supports the review lifecycle while only confirmed actions are effective" do
    actions = CorporateAction.statuses.keys.map do |status|
      build_action(status:, source_reference: status).tap(&:save!)
    end

    assert_equal %w[pending confirmed ignored reversed], actions.map(&:status)
    assert_equal [ actions.second ], CorporateAction.effective.to_a
  end

  test "stores exact Money amounts and reconciles gross tax and net" do
    action = build_action(gross_amount_cents: 12_345, withholding_tax_cents: 1_852, net_amount_cents: 10_493)
    action.save!
    action.reload

    assert_equal Money.from_cents(12_345, "BRL"), action.gross_amount
    assert_equal Money.from_cents(1_852, "BRL"), action.withholding_tax
    assert_equal Money.from_cents(10_493, "BRL"), action.net_amount

    action.net_amount_cents = 10_492
    assert_predicate action, :invalid?
    assert_includes action.errors[:net_amount_cents], "must equal gross amount minus withholding tax"
  end

  test "allows full withholding and defaults withholding to zero" do
    fully_withheld = build_action(gross_amount_cents: 1_000, withholding_tax_cents: 1_000, net_amount_cents: 0)
    untaxed = CorporateAction.new(
      valid_attributes.except(:withholding_tax_cents).merge(net_amount_cents: 1_000)
    )

    assert_predicate fully_withheld, :valid?
    assert_equal 0, untaxed.withholding_tax_cents
    assert_predicate untaxed, :valid?
  end

  test "normalizes currency source reference and notes" do
    action = build_action(
      currency: " brl ", source: " Yahoo_Finance ", source_reference: " event-1 ", notes: "  Paid   normally  "
    )

    assert_predicate action, :valid?
    assert_equal "BRL", action.currency
    assert_equal "yahoo_finance", action.source
    assert_equal "event-1", action.source_reference
    assert_equal "Paid   normally", action.notes

    action.source = "x" * 65
    assert_predicate action, :invalid?
  end

  test "requires the action currency to match the instrument" do
    action = build_action(currency: "USD")

    assert_predicate action, :invalid?
    assert_includes action.errors[:currency], "must match the instrument currency"
  end

  test "requires an institution owned by the action owner" do
    action = build_action(institution: institutions(:other_owner))

    assert_predicate action, :invalid?
    assert_includes action.errors[:institution], "must belong to the income owner"
  end

  test "uses the ex-date for performance and falls back to payment date" do
    paid_on = Date.new(2026, 1, 20)
    action = build_action(paid_on:)

    assert_equal paid_on, action.performance_on

    action.ex_date = paid_on - 5.days
    assert_equal paid_on - 5.days, action.performance_on

    action.ex_date = paid_on + 1.day
    assert_predicate action, :invalid?
    assert_includes action.errors[:ex_date], "must be less than or equal to #{paid_on}"
  end

  test "generates an opaque stable reference and scopes provider references by instrument" do
    action = CorporateAction.create!(valid_attributes.merge(source: "provider", source_reference: "same-event"))
    other = CorporateAction.create!(
      valid_attributes.merge(
        instrument: instruments(:voo_arcx), institution: nil, currency: "USD",
        source: "provider", source_reference: "same-event"
      )
    )

    assert_match(/\Aevt-[a-zA-Z0-9]{12}\z/i, action.slug)
    assert_no_changes -> { action.reload.slug } do
      action.update!(notes: "URL remains stable")
    end
    assert_predicate other, :persisted?

    duplicate = build_action(source: "provider", source_reference: "same-event")
    assert_predicate duplicate, :invalid?

    another_owner = build_action(
      user: users(:one), institution: institutions(:other_owner),
      source: "provider", source_reference: "same-event"
    )
    assert_predicate another_owner, :valid?
  end

  test "prevents referenced financial records from being silently deleted" do
    action = CorporateAction.create!(valid_attributes)

    assert_not action.user.destroy
    assert_not action.instrument.destroy
    assert_not action.institution.destroy
  end

  test "database constraints reject invalid action shapes" do
    attributes = database_attributes
    invalid_attributes = {
      kind: "interest",
      status: "applied",
      paid_on: nil,
      gross_amount_cents: 0,
      withholding_tax_cents: -1,
      net_amount_cents: -1,
      currency: nil
    }

    invalid_attributes.each do |attribute, value|
      assert_raises ActiveRecord::StatementInvalid do
        CorporateAction.insert_all!([ attributes.merge(attribute => value) ])
      end
    end

    assert_raises ActiveRecord::StatementInvalid do
      CorporateAction.insert_all!([ attributes.merge(net_amount_cents: 999) ])
    end

    assert_raises ActiveRecord::StatementInvalid do
      CorporateAction.insert_all!([ attributes.merge(kind: "jcp", currency: "USD") ])
    end

    assert_raises ActiveRecord::StatementInvalid do
      CorporateAction.insert_all!([ attributes.merge(ex_date: attributes.fetch(:paid_on) + 1.day) ])
    end
  end

  private

  def build_action(attributes = {})
    CorporateAction.new(valid_attributes.merge(attributes))
  end

  def valid_attributes
    {
      user: users(:owner),
      instrument: instruments(:petr4_bvmf),
      institution: institutions(:owner_xp),
      kind: :dividend,
      status: :confirmed,
      paid_on: Date.new(2026, 1, 20),
      gross_amount_cents: 1_000,
      withholding_tax_cents: 150,
      net_amount_cents: 850,
      currency: "BRL",
      source: "manual",
      notes: "Quarterly distribution"
    }
  end

  def database_attributes
    {
      user_id: users(:owner).id,
      instrument_id: instruments(:petr4_bvmf).id,
      institution_id: institutions(:owner_xp).id,
      kind: "dividend",
      status: "confirmed",
      paid_on: Date.new(2026, 1, 20),
      gross_amount_cents: 1_000,
      withholding_tax_cents: 0,
      net_amount_cents: 1_000,
      currency: "BRL",
      source: "manual",
      slug: "evt-invalid-action",
      created_at: Time.current,
      updated_at: Time.current
    }
  end
end
