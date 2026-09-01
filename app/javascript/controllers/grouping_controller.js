import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "primaryInput", "secondaryInput", "option"]

  stateClasses = [
    "ui-button-secondary", "rounded-none", "rounded-md", "border", "border-brand-700", "bg-brand-700", "bg-transparent", "text-white", "text-muted", "shadow-inner", "ring-1", "ring-inset", "ring-white/60", "hover:bg-brand-800", "hover:bg-oat", "hover:text-coffee",
    "border-caramel-deep", "bg-caramel", "hover:bg-caramel-deep"
  ]

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
      option.classList.remove(...this.stateClasses)
      option.classList.add(...this.classesFor(slot))
      option.setAttribute("aria-pressed", Boolean(slot).toString())
      option.setAttribute("aria-label", `${option.textContent.trim()}${slot ? `, ${slot} grouping` : ""}`)
      option.dataset.groupingSlot = slot
    })
  }

  classesFor(slot) {
    if (slot === "primary") return [ "rounded-md", "border", "border-brand-700", "bg-brand-700", "text-white", "shadow-inner", "ring-1", "ring-inset", "ring-white/60", "hover:bg-brand-800" ]
    if (slot === "secondary") return [ "rounded-md", "border", "border-caramel-deep", "bg-caramel", "text-white", "shadow-inner", "ring-1", "ring-inset", "ring-white/60", "hover:bg-caramel-deep" ]

    return [ "rounded-none", "bg-transparent", "text-muted", "hover:bg-oat", "hover:text-coffee" ]
  }

  clear() {
    this.primaryInputTarget.value = ""
    this.secondaryInputTarget.value = ""
    this.syncOptions()
    this.formTarget.requestSubmit()
  }
}
