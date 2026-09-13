import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  close() {
    if (!this.element.open) return

    this.element.removeAttribute("open")
    this.element.querySelector("summary")?.focus()
  }
}
