import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["contribution"]

  add(event) {
    const amount = Number(event.currentTarget.dataset.amount)
    const current = Number(this.contributionTarget.value || 0)
    const total = (Number.isFinite(current) ? current : 0) + amount

    this.contributionTarget.value = Number.isInteger(total) ? total : total.toFixed(2)
    this.contributionTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }
}
