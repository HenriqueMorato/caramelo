import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["kind", "ratio", "bonus"]

  connect() {
    this.sync()
  }

  sync() {
    const bonus = this.kindTarget.value === "share_bonus"
    this.ratioTarget.classList.toggle("hidden", bonus)
    this.bonusTarget.classList.toggle("hidden", !bonus)

    this.ratioTarget.querySelectorAll("input").forEach((input) => {
      input.disabled = bonus
      input.required = !bonus
    })

    this.bonusTarget.querySelectorAll("input").forEach((input) => {
      input.disabled = !bonus
      input.required = bonus
    })
  }
}
