import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["nameField", "targetField", "nameSummary", "targetSummary", "removeField", "summary"]

  static values = {
    emptyName: String,
    emptyTarget: String,
    focusOnConnect: Boolean,
    persisted: Boolean,
    removeMessage: String
  }

  connect() {
    this.updateSummary()
    if (this.focusOnConnectValue) {
      setTimeout(() => {
        if (this.element.isConnected) this.summaryTarget.focus({ preventScroll: true })
      }, 0)
    }
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
      this.focusAfterRemoval()
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
    this.focusAfterRemoval()
  }

  focusAfterRemoval() {
    const groups = [...document.querySelectorAll("details[data-controller~='allocation-group']")]
    const currentIndex = groups.indexOf(this.element)
    const nextGroup = groups.slice(currentIndex + 1).find((group) => !group.hidden)
    const previousGroup = groups.slice(0, currentIndex).reverse().find((group) => !group.hidden)
    const target = nextGroup || previousGroup || document.querySelector("[data-portfolio-allocation-add-group]") || document.querySelector("[data-portfolio-allocation-save]")

    const focusTarget = target?.querySelector("summary") || target
    focusTarget?.focus({ preventScroll: true })
  }
}
