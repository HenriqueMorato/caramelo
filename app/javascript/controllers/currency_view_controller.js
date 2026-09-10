import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "button", "panel" ]

  connect() {
    this.show(this.requestedView)
  }

  select({ params: { name } }) {
    this.show(name)
    const url = new URL(window.location)
    url.searchParams.set("currency_view", name)
    window.history.pushState({}, "", url)
  }

  restore() {
    this.show(this.requestedView)
  }

  show(name) {
    const selected = this.panelTargets.some(
      (panel) => panel.dataset.currencyViewName === name
    ) ? name : "native"

    this.panelTargets.forEach((panel) => {
      panel.hidden = panel.dataset.currencyViewName !== selected
    })
    this.buttonTargets.forEach((button) => {
      const active = button.dataset.currencyViewNameParam === selected
      button.setAttribute("aria-pressed", active.toString())
      button.dataset.active = active.toString()
    })
    window.requestAnimationFrame(() => {
      window.dispatchEvent(new CustomEvent("currency-view:changed", { detail: { name: selected } }))
    })
  }

  get requestedView() {
    return new URL(window.location).searchParams.get("currency_view") || "native"
  }
}
