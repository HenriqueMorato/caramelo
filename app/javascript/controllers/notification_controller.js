import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { duration: Number, key: String }

  connect() {
    if (this.keyValue && window.sessionStorage.getItem(this.keyValue)) {
      this.element.remove()
      return
    }

    if (this.keyValue) window.sessionStorage.setItem(this.keyValue, "shown")
    this.timeout = window.setTimeout(() => this.dismiss(), this.durationValue || 3000)
  }

  disconnect() {
    window.clearTimeout(this.timeout)
  }

  dismiss() {
    this.element.remove()
  }
}
