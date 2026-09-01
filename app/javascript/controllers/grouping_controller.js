import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "primaryInput", "secondaryInput", "option"]

  connect() {
    this.syncOptions()
  }

  choose(event) {
    const value = event.currentTarget.dataset.groupingValue
    const primary = this.primaryInputTarget.value
    const secondary = this.secondaryInputTarget.value

    if (value === primary) {
      this.primaryInputTarget.value = secondary
      this.secondaryInputTarget.value = ""
    } else if (value === secondary) {
      this.secondaryInputTarget.value = ""
    } else if (!primary) {
      this.primaryInputTarget.value = value
    } else {
      this.secondaryInputTarget.value = value
    }

    this.syncOptions()
    this.formTarget.requestSubmit()
  }

  syncOptions() {
    const primary = this.primaryInputTarget.value
    const secondary = this.secondaryInputTarget.value

    this.optionTargets.forEach((option) => {
      const value = option.dataset.groupingValue
      const slot = value === primary ? "primary" : value === secondary ? "secondary" : ""
      option.setAttribute("aria-pressed", Boolean(slot).toString())
      const groupingLabel = slot === "primary" ? option.dataset.primaryLabel : option.dataset.secondaryLabel
      option.setAttribute("aria-label", `${option.textContent.trim()}${groupingLabel ? `, ${groupingLabel}` : ""}`)
      option.dataset.groupingSlot = slot
    })
  }

  clear() {
    this.primaryInputTarget.value = ""
    this.secondaryInputTarget.value = ""
    this.syncOptions()
    this.formTarget.requestSubmit()
  }
}
