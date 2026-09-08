require "test_helper"

class Performance::PeriodPresenterTest < ActiveSupport::TestCase
  ClosingValuation = Data.define(:unrealized_gain)
  Period = Data.define(:return_ratio, :gain_loss_amount, :gain_loss, :closing_valuation) do
    def return_available? = return_ratio.present?
  end

  test "formats a positive period" do
    presenter = build_presenter(return_ratio: "0.125", gain_loss: "25", unrealized_gain: "20")

    assert_equal "+12.50%", presenter.return_label
    assert_equal "+R$25,00", presenter.gain_loss_label
    assert_equal "↑", presenter.gain_loss_arrow
    assert_equal "text-leaf", presenter.gain_loss_color_class
    assert_equal "text-positive-on-dark", presenter.unrealized_gain_color_class
  end

  test "formats a negative period" do
    presenter = build_presenter(return_ratio: "-0.05", gain_loss: "-10", unrealized_gain: "-8")

    assert_equal "-5.00%", presenter.return_label
    assert_equal "R$-10,00", presenter.gain_loss_label
    assert_equal "↓", presenter.gain_loss_arrow
    assert_equal "text-guava", presenter.gain_loss_color_class
    assert_equal "text-guava", presenter.unrealized_gain_color_class
  end

  test "uses neutral movement when a return is unavailable" do
    presenter = build_presenter(return_ratio: nil, gain_loss: "0", unrealized_gain: "0")

    assert_nil presenter.return_label
    assert_equal "R$0,00", presenter.gain_loss_label
    assert_equal "→", presenter.gain_loss_arrow
    assert_equal "text-leaf", presenter.gain_loss_color_class
  end

  private

  def build_presenter(return_ratio:, gain_loss:, unrealized_gain:)
    gain_loss_amount = BigDecimal(gain_loss)
    unrealized_gain_amount = BigDecimal(unrealized_gain)
    period = Period.new(
      return_ratio: return_ratio && BigDecimal(return_ratio),
      gain_loss_amount:,
      gain_loss: Money.from_amount(gain_loss_amount, "BRL"),
      closing_valuation: ClosingValuation.new(unrealized_gain: Money.from_amount(unrealized_gain_amount, "BRL"))
    )
    Performance::PeriodPresenter.new(period)
  end
end
