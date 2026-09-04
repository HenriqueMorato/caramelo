import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["currency"]
  static values = { discard: String, originalCurrency: String }

  connect() {
    this.submitting = false
  }

  submit() {
    this.submitting = true
  }

  submitted(event) {
    if (event.detail.success) this.originalCurrencyValue = this.currencyTarget.value
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

  get unsaved() {
    return !this.submitting && this.currencyTarget.value !== this.originalCurrencyValue
  }
}
