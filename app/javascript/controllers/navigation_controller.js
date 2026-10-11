import { Controller } from "@hotwired/stimulus"

const PREFERENCE_EVENT = "navigation:preference-changed"

export default class extends Controller {
  static targets = ["brand", "label", "logo", "toggle", "toggleIcon", "optionalPanel"]
  static values = { storageKey: { type: String, default: "caramelo.navigation.collapsed" } }

  connect() {
    window.addEventListener("storage", this.storageChanged)
    window.addEventListener(PREFERENCE_EVENT, this.preferenceChanged)
    this.apply(this.storedCollapsed)
  }

  disconnect() {
    window.removeEventListener("storage", this.storageChanged)
    window.removeEventListener(PREFERENCE_EVENT, this.preferenceChanged)
  }

  toggle() {
    this.apply(!this.collapsed)
    this.store()
    window.dispatchEvent(new CustomEvent(PREFERENCE_EVENT, { detail: { collapsed: this.collapsed } }))
  }

  apply(collapsed) {
    this.collapsed = collapsed
    this.element.classList.toggle("w-52", !collapsed)
    this.element.classList.toggle("w-20", collapsed)
    this.element.classList.toggle("lg:w-56", !collapsed)
    this.element.classList.toggle("lg:w-20", collapsed)
    this.element.classList.toggle("px-4", !collapsed)
    this.element.classList.toggle("px-2", collapsed)
    this.element.classList.toggle("lg:px-5", !collapsed)
    this.element.classList.toggle("lg:px-2", collapsed)
    this.element.dataset.collapsed = collapsed.toString()

    this.labelTargets.forEach((label) => label.classList.toggle("sr-only", collapsed))
    this.optionalPanelTargets.forEach((panel) => panel.classList.toggle("hidden", collapsed))
    this.brandTarget.classList.toggle("justify-start", !collapsed)
    this.brandTarget.classList.toggle("justify-center", collapsed)
    this.logoTarget.classList.toggle("size-10", !collapsed)
    this.logoTarget.classList.toggle("size-8", collapsed)
    this.toggleTarget.setAttribute("aria-expanded", (!collapsed).toString())
    this.toggleTarget.setAttribute("aria-label", this.toggleLabel)
    this.toggleIconTarget.classList.toggle("rotate-180", collapsed)
  }

  store() {
    try {
      window.localStorage.setItem(this.storageKeyValue, this.collapsed.toString())
    } catch (_) {
      // The sidebar still toggles when persistent storage is unavailable.
    }
  }

  get storedCollapsed() {
    try {
      return window.localStorage.getItem(this.storageKeyValue) === "true"
    } catch (_) {
      return false
    }
  }

  storageChanged = (event) => {
    if (event.key !== this.storageKeyValue) return

    this.apply(event.newValue === "true")
  }

  preferenceChanged = (event) => this.apply(event.detail.collapsed)

  get toggleLabel() {
    return this.collapsed ? this.element.dataset.navigationExpandLabel : this.element.dataset.navigationCollapseLabel
  }
}
