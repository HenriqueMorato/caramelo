require "test_helper"

class CorporateActionTest < ActiveSupport::TestCase
  test "converts a decimal share bonus percentage to an exact ratio" do
    action = build_quantity_action(kind: :share_bonus, ratio_numerator: nil, ratio_denominator: nil)
    action.bonus_percentage = "2.5"

    assert action.valid?, action.errors.full_messages.inspect
    assert_equal 41, action.ratio_numerator
    assert_equal 40, action.ratio_denominator
    assert_equal "2.5", action.bonus_percentage
  end

  test "rejects invalid share bonus percentages" do
    [ "", "0", "-1", "NaN", "Infinity", "abc", "1e1000000", "0.0000000000000000001" ].each do |percentage|
      action = build_quantity_action(kind: :share_bonus, ratio_numerator: nil, ratio_denominator: nil)
      action.bonus_percentage = percentage

      assert_not action.valid?
      assert_includes action.errors[:bonus_percentage], "must be a positive, finite number"
    end
  end

  test "rejects ratios larger than SQLite can persist" do
    action = build_quantity_action(ratio_numerator: CorporateAction::RATIO_INTEGER_MAX + 1)

    assert_not action.valid?
    assert_includes action.errors[:ratio_numerator], "must be less than or equal to 9223372036854775807"
  end
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

  test "supports exact quantity ratios for splits reverse splits and share bonuses" do
    split = build_quantity_action(kind: :stock_split, ratio_numerator: 2, ratio_denominator: 1)
    reverse_split = build_quantity_action(
      kind: :reverse_split, ratio_numerator: 1, ratio_denominator: 10
    )
    bonus = build_quantity_action(kind: :share_bonus, ratio_numerator: 11, ratio_denominator: 10)

    assert_predicate split, :valid?
    assert_predicate reverse_split, :valid?
    assert_predicate bonus, :valid?
    assert_equal 2.to_r, split.quantity_multiplier
    assert_equal Rational(1, 10), reverse_split.quantity_multiplier
    assert_equal Rational(11, 10), bonus.quantity_multiplier
    assert_equal split.effective_on, split.performance_on
  end

  test "requires a ratio direction that matches the quantity action kind" do
    split = build_quantity_action(kind: :stock_split, ratio_numerator: 1, ratio_denominator: 2)
    reverse_split = build_quantity_action(
      kind: :reverse_split, ratio_numerator: 2, ratio_denominator: 1
    )
    unchanged = build_quantity_action(kind: :share_bonus, ratio_numerator: 1, ratio_denominator: 1)

    assert_predicate split, :invalid?
    assert_predicate reverse_split, :invalid?
    assert_predicate unchanged, :invalid?
    assert split.errors[:ratio_numerator].any?
    assert reverse_split.errors[:ratio_numerator].any?
    assert unchanged.errors[:ratio_numerator].any?
  end

  test "keeps cash and quantity action fields mutually exclusive" do
    quantity_action = build_quantity_action(paid_on: Date.new(2026, 1, 20))
    cash_action = build_action(effective_on: Date.new(2026, 1, 20), ratio_numerator: 2, ratio_denominator: 1)

    assert_predicate quantity_action, :invalid?
    assert_predicate cash_action, :invalid?
  end

  test "pairs an exact cash-in-lieu quantity with money in the instrument currency" do
    action = build_quantity_action(
      cash_in_lieu_quantity: BigDecimal("0.25"), cash_in_lieu_amount_cents: 375, currency: "BRL"
    )
    action.save!

    assert_equal BigDecimal("0.25"), action.reload.cash_in_lieu_quantity
    assert_equal Money.from_cents(375, "BRL"), action.cash_in_lieu_amount

    missing_amount = build_quantity_action(cash_in_lieu_quantity: BigDecimal("0.25"), currency: "BRL")
    missing_quantity = build_quantity_action(cash_in_lieu_amount_cents: 375, currency: "BRL")

    assert_predicate missing_amount, :invalid?
    assert_predicate missing_quantity, :invalid?
  end

  test "does not require a currency for a cash-free quantity action" do
    action = build_quantity_action

    assert_nil action.currency
    assert_not_predicate action, :monetary_action?
    assert_predicate action, :valid?
    assert_nil build_action.quantity_multiplier
  end


  test "reports a handled position-refresh enqueue failure without rolling back the action" do
    action = build_quantity_action
    original = RefreshPositionMaterializationJob.method(:perform_later)
    reporter = Rails.error
    original_report = reporter.method(:report)
    reported = nil
    RefreshPositionMaterializationJob.define_singleton_method(:perform_later) { |**| raise "queue unavailable" }
    reporter.define_singleton_method(:report) { |error, **| reported = error }
    assert action.save

    assert_predicate action, :persisted?
    assert_equal "queue unavailable", reported.message
  ensure
    RefreshPositionMaterializationJob.define_singleton_method(:perform_later, original)
    reporter&.define_singleton_method(:report, original_report)
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

  test "confirmed quantity actions cannot take effect in the future" do
    confirmed = build_quantity_action(effective_on: Date.current + 1.day)
    pending = build_quantity_action(effective_on: Date.current + 1.day, status: :pending)

    assert_predicate confirmed, :invalid?
    assert_includes confirmed.errors[:effective_on], "must be less than or equal to #{Date.current}"
    assert_predicate pending, :valid?
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

  test "finds the earliest effective performance date through a scoped relation" do
    later = build_action(paid_on: Date.new(2026, 1, 20), source_reference: "later")
    earlier = build_action(
      paid_on: Date.new(2026, 1, 18), ex_date: Date.new(2026, 1, 10), source_reference: "earlier"
    )
    ignored = build_action(
      status: :ignored, paid_on: Date.new(2026, 1, 5), source_reference: "ignored"
    )
    future = build_action(paid_on: Date.new(2026, 2, 1), source_reference: "future")
    split = build_quantity_action(effective_on: Date.new(2026, 1, 8), source_reference: "split")
    [ later, earlier, ignored, future, split ].each(&:save!)

    scope = CorporateAction.where(instrument: instruments(:petr4_bvmf))
      .effective_on_or_before(Date.new(2026, 1, 31))

    assert_equal Date.new(2026, 1, 8), scope.minimum_performance_on
    assert_equal [ split, earlier, later ], scope.reverse_chronological.reverse.to_a
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

    quantity_attributes = database_quantity_attributes
    invalid_quantity_attributes = [
      { ratio_numerator: 0 },
      { ratio_denominator: 0 },
      { kind: "split", ratio_numerator: 1, ratio_denominator: 2 },
      { kind: "reverse_split", ratio_numerator: 2, ratio_denominator: 1 },
      { cash_in_lieu_quantity: BigDecimal("0.25") },
      { cash_in_lieu_amount_cents: 100, currency: "BRL" },
      { cash_in_lieu_quantity: BigDecimal("-0.25"), cash_in_lieu_amount_cents: 100, currency: "BRL" },
      { cash_in_lieu_quantity: BigDecimal("0.25"), cash_in_lieu_amount_cents: -1, currency: "BRL" }
    ]
    invalid_quantity_attributes.each do |invalid|
      assert_raises ActiveRecord::StatementInvalid do
        CorporateAction.insert_all!([ quantity_attributes.merge(invalid) ])
      end
    end
  end

  private

  def build_action(attributes = {})
    CorporateAction.new(valid_attributes.merge(attributes))
  end

  def build_quantity_action(attributes = {})
    CorporateAction.new(quantity_attributes.merge(attributes))
  end

  def quantity_attributes
    {
      user: users(:owner),
      instrument: instruments(:petr4_bvmf),
      institution: institutions(:owner_xp),
      kind: :stock_split,
      status: :confirmed,
      effective_on: Date.new(2026, 1, 15),
      ratio_numerator: 2,
      ratio_denominator: 1,
      currency: nil,
      source: "manual",
      notes: "Two new shares for each old share"
    }
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

  def database_quantity_attributes
    {
      user_id: users(:owner).id,
      instrument_id: instruments(:petr4_bvmf).id,
      institution_id: institutions(:owner_xp).id,
      kind: "split",
      status: "confirmed",
      effective_on: Date.new(2026, 1, 15),
      ratio_numerator: 2,
      ratio_denominator: 1,
      source: "manual",
      slug: "evt-invalid-quantity-action",
      created_at: Time.current,
      updated_at: Time.current
    }
  end
end
