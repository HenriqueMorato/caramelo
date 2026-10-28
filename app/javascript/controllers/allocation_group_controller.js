import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["nameField", "targetField", "nameSummary", "targetSummary", "removeField"]

  static values = {
    emptyName: String,
    emptyTarget: String,
    persisted: Boolean,
    removeMessage: String
  }

  connect() {
    this.updateSummary()
  }

  updateSummary() {
    if (this.hasNameSummaryTarget) {
      this.nameSummaryTarget.textContent = this.nameFieldTarget.value.trim() || this.emptyNameValue
    }

    if (this.hasTargetSummaryTarget) {
      const target = this.targetFieldTarget.value.trim()
      this.targetSummaryTarget.textContent = target ? `${target}%` : this.emptyTargetValue
    }
  }

  remove(event) {
    event.preventDefault()

    if (this.removeMessageValue && !window.confirm(this.removeMessageValue)) return

    if (!this.persistedValue) {
      this.element.remove()
      return
    }

    this.removeFieldTarget.value = "1"
    this.element.hidden = true
    this.element.setAttribute("aria-hidden", "true")
    this.element.dataset.removed = "true"
    this.element.querySelectorAll("input, select, textarea").forEach((control) => {
      if (control !== this.removeFieldTarget) control.disabled = true
    })
  }
}
