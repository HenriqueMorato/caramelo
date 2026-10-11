import { Controller } from "@hotwired/stimulus"

const PREFERENCE_EVENT = "navigation:preference-changed"

export default class extends Controller {
  static targets = ["option"]
  static values = { storageKey: { type: String, default: "caramelo.navigation.collapsed" } }

  connect() {
    window.addEventListener("storage", this.storageChanged)
    window.addEventListener(PREFERENCE_EVENT, this.preferenceChanged)
    this.sync()
  }

  disconnect() {
    window.removeEventListener("storage", this.storageChanged)
    window.removeEventListener(PREFERENCE_EVENT, this.preferenceChanged)
  }

  change(event) {
    const collapsed = event.target.value === "collapsed"
    this.store(collapsed)
    window.dispatchEvent(new CustomEvent(PREFERENCE_EVENT, { detail: { collapsed } }))
    this.sync()
  }

  sync() {
    const selectedValue = this.collapsed ? "collapsed" : "open"
    this.optionTargets.forEach((option) => {
      option.checked = option.value === selectedValue
    })
  }

  storageChanged = (event) => {
    if (event.key !== this.storageKeyValue) return

    this.sync()
  }

  preferenceChanged = () => this.sync()

  store(collapsed) {
    try {
      window.localStorage.setItem(this.storageKeyValue, collapsed.toString())
    } catch (_) {
      // The preference still applies to the current page when storage is unavailable.
    }
  }

  get collapsed() {
    try {
      return window.localStorage.getItem(this.storageKeyValue) === "true"
    } catch (_) {
      return false
    }
  }
}
