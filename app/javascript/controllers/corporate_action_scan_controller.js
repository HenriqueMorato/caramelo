import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { reload: Boolean, url: String }

  connect() {
    if (!this.reloadValue) return

    this.timeout = window.setTimeout(() => {
      Turbo.visit(this.urlValue, { action: "replace" })
    }, 250)
  }

  disconnect() {
    window.clearTimeout(this.timeout)
  }
}
