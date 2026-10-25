import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "assetField" ]

  connect() {
    this.balanceAssetFields()
  }

  balance(event) {
    if (event?.currentTarget?.dataset.autoFilled === "true") {
      delete event.currentTarget.dataset.autoFilled
    }

    this.balanceAssetFields()
  }

  balanceAssetFields() {
    const fields = this.assetFieldTargets
    const autoFilledFields = fields.filter((field) => field.dataset.autoFilled === "true")
    autoFilledFields.forEach((field) => {
      field.value = ""
      delete field.dataset.autoFilled
    })

    const filledFields = fields.filter((field) => field.value.trim() !== "")
    const blankFields = fields.filter((field) => field.value.trim() === "")
    if (filledFields.length === 0 || blankFields.length === 0) return

    const total = filledFields.reduce((sum, field) => sum + Number(field.value), 0)
    const remainder = 100 - total
    if (!Number.isFinite(total) || remainder <= 0) return

    const share = Math.floor((remainder / blankFields.length) * 100) / 100
    let assigned = 0
    blankFields.forEach((field, index) => {
      const value = index === blankFields.length - 1 ? remainder - assigned : share
      field.value = value.toFixed(2)
      field.dataset.autoFilled = "true"
      assigned += value
    })
  }
}
