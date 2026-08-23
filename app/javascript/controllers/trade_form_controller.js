import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "instrument", "currency", "fees", "institution" ]

  connect() {
    this.syncCurrency()
  }

  syncCurrency(event) {
    if (!this.hasInstrumentTarget || !this.hasCurrencyTarget) return

    const option = this.instrumentTarget.selectedOptions[0]
    this.currencyTarget.value = option?.dataset.currency || ""

    if (option?.dataset.subunit) {
      const step = 1 / Number(option.dataset.subunit)
      this.feesTarget.step = step
    }

    if (event && this.hasInstitutionTarget) {
      this.institutionTarget.value = option?.dataset.lastInstitutionId || ""
    }
  }
}
