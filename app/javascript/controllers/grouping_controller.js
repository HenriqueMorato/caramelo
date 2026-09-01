import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "primaryInput", "secondaryInput", "primaryMenu", "secondaryMenu", "primaryLabel", "secondaryLabel", "primaryButton", "secondaryButton"]

  connect() {
    this.syncSecondaryOptions()
  }

  submit() {
    this.syncSecondaryOptions()
    this.formTarget.requestSubmit()
  }

  toggle(event) {
    const menu = event.currentTarget.dataset.groupingMenu === "primary" ? this.primaryMenuTarget : this.secondaryMenuTarget
    const expanded = event.currentTarget.getAttribute("aria-expanded") === "true"
    this.closeMenus()
    if (!expanded) {
      menu.hidden = false
      event.currentTarget.setAttribute("aria-expanded", "true")
    }
  }

  choose(event) {
    const value = event.currentTarget.dataset.groupingValue
    const primary = event.currentTarget.closest("[data-grouping-menu='primary']")
    if (primary) {
      this.primaryInputTarget.value = value
      if (value === "" || value === this.secondaryInputTarget.value) {
        this.secondaryInputTarget.value = ""
        this.secondaryLabelTarget.textContent = this.secondaryMenuTarget.querySelector('[data-grouping-value=""]').textContent
      }
      this.primaryLabelTarget.textContent = event.currentTarget.textContent
    } else {
      this.secondaryInputTarget.value = value
      this.secondaryLabelTarget.textContent = event.currentTarget.textContent
    }
    this.syncSecondaryOptions()
    this.closeMenus()
    this.formTarget.requestSubmit()
  }

  syncSecondaryOptions() {
    this.secondaryMenuTarget.querySelectorAll("[data-grouping-value]").forEach((option) => {
      const disabled = option.dataset.groupingValue !== "" && option.dataset.groupingValue === this.primaryInputTarget.value
      option.disabled = disabled
      option.toggleAttribute("disabled", disabled)
      option.setAttribute("aria-disabled", disabled.toString())
      option.classList.toggle("line-through", disabled)
      option.classList.toggle("opacity-50", disabled)
    })
    if (this.secondaryInputTarget.value === this.primaryInputTarget.value) {
      this.secondaryInputTarget.value = ""
      this.secondaryLabelTarget.textContent = this.secondaryMenuTarget.querySelector('[data-grouping-value=""]').textContent
    }
  }

  closeMenus() {
    this.primaryMenuTarget.hidden = true
    this.secondaryMenuTarget.hidden = true
    this.primaryButtonTarget.setAttribute("aria-expanded", "false")
    this.secondaryButtonTarget.setAttribute("aria-expanded", "false")
  }

  closeOnOutside(event) {
    if (!this.element.contains(event.target)) this.closeMenus()
  }

  clear() {
    this.primaryInputTarget.value = ""
    this.secondaryInputTarget.value = ""
    this.primaryLabelTarget.textContent = this.primaryMenuTarget.querySelector('[data-grouping-value=""]').textContent
    this.secondaryLabelTarget.textContent = this.secondaryMenuTarget.querySelector('[data-grouping-value=""]').textContent
    this.syncSecondaryOptions()
    this.closeMenus()
    this.formTarget.requestSubmit()
  }
}
