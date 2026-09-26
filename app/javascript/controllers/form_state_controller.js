import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { discard: String, dirty: Boolean }

  connect() {
    this.submitting = false
  }

  markDirty() {
    this.dirtyValue = true
  }

  submit() {
    this.submitting = true
  }

  submitted(event) {
    if (event.detail.success) this.dirtyValue = false
    this.submitting = false
  }

  confirmNavigation(event) {
    if (this.unsaved && !window.confirm(this.discardValue)) event.preventDefault()
  }

  beforeUnload(event) {
    if (!this.unsaved) return

    event.preventDefault()
    event.returnValue = ""
  }

  get unsaved() {
    return !this.submitting && this.dirtyValue
  }
}
