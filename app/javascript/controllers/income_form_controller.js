import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "instrument", "kindField", "kind", "hiddenKind", "gross", "tax", "net",
    "institutionField", "institution", "hiddenInstitution"
  ]
  static values = {
    currency: String, subunit: Number, discard: String, dirty: Boolean,
    institutions: Object, institution: Number, noInstitution: String
  }

  connect() {
    this.submitting = false
    this.syncInstrument()
  }

  markDirty() {
    this.dirtyValue = true
  }

  submit() {
    this.submitting = true
  }

  submitted(event) {
    if (event.detail.success) this.dirtyValue = false
    this.submitting = false
  }

  confirmNavigation(event) {
    if (this.unsaved && !window.confirm(this.discardValue)) event.preventDefault()
  }

  beforeUnload(event) {
    if (!this.unsaved) return

    event.preventDefault()
    event.returnValue = ""
  }

  syncInstrument(event) {
    this.syncCurrency()
    this.syncKind(event)
    this.syncInstitution()
  }

  syncCurrency() {
    if (this.hasInstrumentTarget) {
      const option = this.instrumentTarget.selectedOptions?.[0]
      if (option?.dataset.currency) {
        this.currencyValue = option.dataset.currency
        this.subunitValue = Number(option.dataset.subunit)
      }
    }

    this.updateNet()
  }

  syncKind(event) {
    const supportsJcp = this.currencyValue === "BRL"
    this.kindFieldTarget.hidden = !supportsJcp
    this.kindTarget.disabled = !supportsJcp
    this.hiddenKindTarget.disabled = supportsJcp
    if (!supportsJcp && this.kindTarget.value !== "dividend") {
      this.kindTarget.value = "dividend"
      this.kindTarget.dispatchEvent(new Event("change", { bubbles: Boolean(event) }))
    }
  }

  syncInstitution() {
    const entries = this.institutionsValue[String(this.instrumentTarget.value)] || []
    const hasChoice = entries.length > 1
    const hasSingleInstitution = entries.length === 1

    this.institutionFieldTarget.hidden = !hasChoice
    this.institutionTarget.disabled = !hasChoice
    this.hiddenInstitutionTarget.disabled = !hasSingleInstitution
    this.hiddenInstitutionTarget.value = hasSingleInstitution ? entries[0].id : ""

    if (!hasChoice) return

    const selected = String(this.institutionValue || "")
    this.institutionTarget.replaceChildren(new Option(this.noInstitutionValue, ""))
    entries.forEach(({ id, name }) => this.institutionTarget.add(new Option(name, id)))
    if (entries.some(({ id }) => String(id) === selected)) this.institutionTarget.value = selected
  }

  updateNet() {
    const gross = this.parseAmount(this.grossTarget.value)
    const tax = this.parseAmount(this.taxTarget.value || "0")
    if (gross === null || tax === null || !this.currencyValue) {
      this.netTarget.textContent = "—"
      return
    }

    const precision = Math.log10(this.subunitValue || 100)
    this.netTarget.textContent = new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: this.currencyValue,
      minimumFractionDigits: precision,
      maximumFractionDigits: precision
    }).format(gross - tax)
  }

  parseAmount(value) {
    if (value.trim() === "") return null

    const amount = Number(value)
    return Number.isFinite(amount) ? amount : null
  }

  get unsaved() {
    return !this.submitting && this.dirtyValue
  }
}
