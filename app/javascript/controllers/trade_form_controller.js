import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "instrument",
    "currency",
    "fees",
    "institution",
    "settlement",
    "settlementRate",
    "settlementDirection"
  ]
  static values = { reportingCurrency: String }

  connect() {
    this.syncCurrency()
    this.syncSettlement()
  }

  syncCurrency(event) {
    if (!this.hasInstrumentTarget || !this.hasCurrencyTarget) return

    const option = this.instrumentTarget.selectedOptions[0]
    this.currencyTarget.value = option?.dataset.currency || ""

    if (event && this.hasSettlementRateTarget) this.settlementRateTarget.value = ""

    if (option?.dataset.subunit) {
      const step = 1 / Number(option.dataset.subunit)
      this.feesTarget.step = step
    }

    if (event && this.hasInstitutionTarget) {
      this.institutionTarget.value = option?.dataset.lastInstitutionId || ""
    }

    this.syncSettlement()
  }

  syncSettlement() {
    if (!this.hasSettlementTarget) return

    const nativeCurrency = this.currencyTarget.value
    const foreign = Boolean(nativeCurrency) && nativeCurrency !== this.reportingCurrencyValue
    this.settlementTarget.hidden = !foreign

    if (this.hasSettlementDirectionTarget) {
      this.settlementDirectionTarget.textContent = `1 ${nativeCurrency} = … ${this.reportingCurrencyValue}`
    }
  }
}
