import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["currency"]
  static values = { discard: String }

  connect() {
    this.originalCurrency = this.currencyTarget.value
    this.submitting = false
  }

  submit() {
    this.submitting = true
    this.element.querySelector("button[type=submit]").disabled = true
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
    return !this.submitting && this.currencyTarget.value !== this.originalCurrency
  }
}
