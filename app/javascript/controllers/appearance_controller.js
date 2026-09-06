import { Controller } from "@hotwired/stimulus"

const VALID_APPEARANCES = ["light", "dark", "system"]
const THEME_COLORS = { light: "#f6efe4", dark: "#17120f" }

export default class extends Controller {
  static targets = ["label", "menu", "option"]
  static values = { storageKey: { type: String, default: "local_folio.appearance" } }

  connect() {
    this.systemPreference = window.matchMedia("(prefers-color-scheme: dark)")
    this.systemPreference.addEventListener("change", this.systemPreferenceChanged)
    this.apply(this.appearance, { persist: false })
  }

  disconnect() {
    this.systemPreference?.removeEventListener("change", this.systemPreferenceChanged)
  }

  select(event) {
    const { mode } = event.params
    this.apply(mode, { persist: true })
  }

  closeMenus(event) {
    if (event.type === "click" && this.menuTargets.some((menu) => menu.contains(event.target))) return

    this.menuTargets.forEach((menu) => menu.removeAttribute("open"))
  }

  storedPreferenceChanged(event) {
    if (event.key !== this.storageKeyValue) return

    this.apply(this.validAppearance(event.newValue), { persist: false })
  }

  refreshControls() {
    this.apply(this.appearance, { persist: false })
  }

  optionTargetConnected(option) {
    this.syncOption(option)
  }

  systemPreferenceChanged = () => {
    if (this.appearance === "system") this.apply("system", { persist: false })
  }

  apply(appearance, { persist }) {
    const selectedAppearance = this.validAppearance(appearance)
    const theme = this.resolvedTheme(selectedAppearance)

    if (persist) this.store(selectedAppearance)

    this.element.dataset.appearance = selectedAppearance
    this.element.dataset.theme = theme
    this.element.style.colorScheme = theme
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", THEME_COLORS[theme])
    this.syncControls()
    window.dispatchEvent(new CustomEvent("appearance:change", { detail: { appearance: selectedAppearance, theme } }))
  }

  syncControls() {
    this.optionTargets.forEach((option) => this.syncOption(option))
    this.labelTargets.forEach((label) => {
      label.textContent = label.dataset[this.appearance]
    })
  }

  syncOption(option) {
    const selected = option.dataset.appearanceMode === this.appearance
    option.setAttribute("aria-pressed", selected.toString())
    option.dataset.active = selected.toString()
  }

  store(appearance) {
    try {
      window.localStorage.setItem(this.storageKeyValue, appearance)
    } catch (_) {
      // The active page still changes when persistent storage is unavailable.
    }
  }

  validAppearance(appearance) {
    return VALID_APPEARANCES.includes(appearance) ? appearance : "system"
  }

  resolvedTheme(appearance) {
    if (appearance !== "system") return appearance

    return this.systemPreference.matches ? "dark" : "light"
  }

  get appearance() {
    return this.validAppearance(this.element.dataset.appearance)
  }
}
