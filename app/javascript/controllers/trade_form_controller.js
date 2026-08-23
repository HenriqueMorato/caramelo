import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "instrument", "currency", "fees" ]

  connect() {
    this.syncCurrency()
  }

  syncCurrency() {
    if (!this.hasInstrumentTarget || !this.hasCurrencyTarget) return

    const option = this.instrumentTarget.selectedOptions[0]
    this.currencyTarget.value = option?.dataset.currency || ""

    if (option?.dataset.subunit) {
      const step = 1 / Number(option.dataset.subunit)
      this.feesTarget.step = step
    }
  }
}
