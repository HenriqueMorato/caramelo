import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["all", "item"]

  toggleAll() {
    this.itemTargets.filter((item) => !item.disabled).forEach((item) => { item.checked = this.allTarget.checked })
  }
}
