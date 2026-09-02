import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { duration: Number }

  connect() {
    this.timeout = window.setTimeout(() => this.dismiss(), this.durationValue || 3000)
  }

  disconnect() {
    window.clearTimeout(this.timeout)
  }

  dismiss() {
    this.element.remove()
  }
}
