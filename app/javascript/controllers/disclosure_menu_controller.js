import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  closeOnOutside(event) {
    if (this.element.open && !this.element.contains(event.target)) {
      this.element.removeAttribute("open")
    }
  }

  closeOnEscape() {
    if (!this.element.open) return

    this.element.removeAttribute("open")
    this.element.querySelector("summary")?.focus()
  }
}
