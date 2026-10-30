import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "assetField", "assetRange", "assetOutput", "assetBar",
    "assetMixSegment", "assetTooltip",
    "instrumentField", "instrumentRange", "instrumentOutput", "instrumentBar",
    "allocationTotal", "allocationStatus"
  ]

  connect() {
    if (this.element.dataset.invalid !== "true") this.balanceAllFields()
    this.syncControls()
  }

  balance(event) {
    const field = event?.currentTarget
    if (!field) return

    if (field.dataset.autoFilled === "true") {
      delete field.dataset.autoFilled
    }

    if (field.value.trim() === "") {
      this.syncControls()
      return
    }

    this.balanceFields(this.fieldsFor(field))
    this.syncControls()
  }

  prepare(event) {
    const field = event?.currentTarget
    if (!field || field.dataset.autoFilled !== "true") return

    field.value = ""
    delete field.dataset.autoFilled
    this.syncControls()
  }

  move(event) {
    const range = event.currentTarget
    const fields = range.dataset.portfolioTargetType === "instrument" ? this.instrumentFieldTargets : this.assetFieldTargets
    const field = fields.find((candidate) => this.matchesRange(candidate, range))
    if (!field) return

    field.value = range.value
    if (field.dataset.autoFilled === "true") delete field.dataset.autoFilled
    this.balanceFields(this.fieldsFor(field))
    this.syncControls()
  }

  fieldsFor(field) {
    if (field.dataset.portfolioTargetType === "instrument") {
      return this.instrumentFieldTargets.filter((candidate) => candidate.dataset.assetKey === field.dataset.assetKey)
    }

    return this.assetFieldTargets
  }

  matchesRange(field, range) {
    return field.dataset.assetKey === range.dataset.assetKey &&
      (range.dataset.portfolioTargetType !== "instrument" || field.dataset.instrumentKey === range.dataset.instrumentKey)
  }

  balanceAllFields() {
    this.balanceFields(this.assetFieldTargets)

    Array.from(new Set(this.instrumentFieldTargets.map((field) => field.dataset.assetKey))).forEach((assetKey) => {
      this.balanceFields(this.instrumentFieldTargets.filter((field) => field.dataset.assetKey === assetKey))
    })
  }

  balanceFields(fields) {
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

  syncControls() {
    this.syncRangeControls(
      this.assetRangeTargets,
      this.assetFieldTargets,
      this.assetOutputTargets,
      this.assetBarTargets.filter((bar) => !bar.classList.contains("portfolio-plan-mix-segment"))
    )
    this.syncRangeControls(this.instrumentRangeTargets, this.instrumentFieldTargets, this.instrumentOutputTargets, this.instrumentBarTargets)
    this.syncMixSegments()
    this.syncAllocationSummary()
  }

  syncMixSegments() {
    const total = this.assetFieldTargets.reduce((sum, field) => {
      const value = Number(field.value)
      return Number.isFinite(value) && value > 0 ? sum + value : sum
    }, 0)

    this.assetMixSegmentTargets.forEach((segment) => {
      const field = this.assetFieldTargets.find((candidate) => candidate.dataset.assetKey === segment.dataset.assetKey)
      const value = Number(field?.value)
      const percentage = total > 0 && Number.isFinite(value) ? (value / total) * 100 : 0
      const formatted = this.formatPercentage(percentage)
      const label = segment.dataset.assetLabel

      segment.style.width = `${percentage}%`
      if (!label) return

      segment.dataset.tooltip = `${label} · ${formatted}%`
      segment.setAttribute("aria-label", `${label}: ${formatted}%`)
    })
  }

  showMixTooltip(event) {
    if (!this.hasAssetTooltipTarget) return

    const segment = event.currentTarget
    const mix = segment.closest(".portfolio-plan-mix")
    if (!mix) return

    const segmentRect = segment.getBoundingClientRect()
    const mixRect = mix.getBoundingClientRect()
    const tooltip = this.assetTooltipTarget
    tooltip.textContent = segment.dataset.tooltip || segment.getAttribute("aria-label") || ""
    tooltip.style.left = `${segmentRect.left + (segmentRect.width / 2) - mixRect.left}px`
    tooltip.style.top = `${segmentRect.top - mixRect.top}px`
    tooltip.dataset.visible = "true"
  }

  hideMixTooltip() {
    if (this.hasAssetTooltipTarget) delete this.assetTooltipTarget.dataset.visible
  }

  syncAllocationSummary() {
    const total = this.assetFieldTargets.reduce((sum, field) => {
      const value = Number(field.value)
      return Number.isFinite(value) ? sum + value : sum
    }, 0)
    const normalized = Math.round(total * 100) / 100

    this.allocationTotalTargets.forEach((target) => {
      target.textContent = `${this.formatPercentage(normalized)}%`
    })
    this.allocationStatusTargets.forEach((target) => {
      target.dataset.complete = Math.abs(normalized - 100) <= 0.01 ? "true" : "false"
    })
  }

  syncRangeControls(ranges, fields, outputs, bars) {
    ranges.forEach((range) => {
      const field = fields.find((candidate) => this.matchesRange(candidate, range))
      const value = Number(field?.value)
      const normalized = Number.isFinite(value) ? Math.min(100, Math.max(0, value)) : 0
      range.value = normalized
      const formatted = this.formatPercentage(normalized)

      const output = outputs.find((candidate) => this.matchesRange(candidate, range))
      if (output) output.textContent = `${formatted}%`

      bars.filter((candidate) => this.matchesRange(candidate, range)).forEach((bar) => {
        bar.style.width = `${normalized}%`
        if (bar.getAttribute("role") === "progressbar") bar.setAttribute("aria-valuenow", normalized)
      })
    })
  }

  formatPercentage(value) {
    return Number.isInteger(value) ? value.toString() : value.toFixed(2).replace(/0+$/, "").replace(/\.$/, "")
  }
}
