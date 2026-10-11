import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "kind",
    "ratio",
    "bonus",
    "instrument",
    "effectiveOn",
    "ratioNumerator",
    "ratioDenominator",
    "bonusPercentage",
    "cashInLieuQuantity",
    "cashInLieuAmount",
    "previewPanel",
    "previewAsset",
    "previewInstrument",
    "previewDate",
    "previewTag",
    "previewCopy",
    "previewFractionalNote",
    "previewCash"
  ]

  static values = {
    contextAsset: String,
    contextInstrument: String,
    contextCurrency: String
  }

  connect() {
    this.refreshPreview()
  }

  sync() {
    const bonus = this.selectedKind() === "share_bonus"
    this.ratioTarget?.classList.toggle("hidden", bonus)
    this.bonusTarget?.classList.toggle("hidden", !bonus)

    this.ratioTarget?.querySelectorAll("input").forEach((input) => {
      input.disabled = bonus
      input.required = !bonus
    })

    this.bonusTarget?.querySelectorAll("input").forEach((input) => {
      input.disabled = !bonus
      input.required = bonus
    })
  }

  refreshPreview() {
    if (!this.hasPreviewPanelTarget) return

    this.sync()
    const kind = this.selectedKind()
    const instrument = this.instrumentDetails()

    this.previewAssetTarget.textContent = instrument.asset || this.previewAssetTarget.dataset.placeholder
    this.previewInstrumentTarget.textContent = instrument.name || this.previewInstrumentTarget.dataset.placeholder
    this.previewDateTarget.textContent = this.dateText()
    this.previewTagTarget.textContent = this.labelFor(kind).toUpperCase()
    const preview = this.previewFor(kind, instrument)
    this.renderPreviewCopy(preview)
    this.previewFractionalNoteTarget.textContent = preview.note
    this.previewFractionalNoteTarget.hidden = !preview.note
    this.previewCashTarget.textContent = this.cashText(instrument.currency)
  }

  resetPreview() {
    window.setTimeout(() => this.refreshPreview(), 0)
  }

  renderPreviewCopy(preview) {
    if (!preview.current) {
      this.previewCopyTarget.textContent = preview.copy
      return
    }

    const data = this.previewPanelTarget.dataset
    const resultText = preview.result ? preview.resultText : "…"
    const resultUnit = preview.result ? this.unitLabel(preview.result) : data.quantityActionFormCopyUnitValue
    const cashCopy = preview.cashQuantity
      ? ` ${(data.quantityActionFormCashInLieuCopyValue || "%{cash} fractional %{cash_unit} is paid in cash.")
        .replace("%{cash}", this.formatDecimal(preview.cashQuantity))
        .replace("%{cash_unit}", this.unitLabel(preview.cashQuantity))}`
      : ""

    this.previewCopyTarget.replaceChildren(
      document.createTextNode(`${data.quantityActionFormCopyLeadValue || "Your"} `),
      this.quantitySpan(`${this.formatDecimal(preview.current)} ${this.unitLabel(preview.current)}`, "before"),
      document.createTextNode(` ${data.quantityActionFormCopyTransitionValue || "become"} `),
      this.quantitySpan(`${resultText} ${resultUnit || "shares"}`, "after"),
      document.createTextNode(`.${cashCopy}`)
    )
  }

  quantitySpan(value, position) {
    const span = document.createElement("span")
    span.className = `action-preview-quantity action-preview-quantity-${position}`
    span.textContent = value
    return span
  }

  selectedKind() {
    return this.kindTargets.find((input) => input.checked)?.value || "stock_split"
  }

  instrumentDetails() {
    const option = this.instrumentTarget?.selectedOptions?.[0]
    const data = option?.dataset || this.instrumentTarget?.dataset || {}

    return {
      asset: data.previewAsset || this.contextAssetValue,
      name: data.previewInstrument || this.contextInstrumentValue,
      currency: data.currency || this.contextCurrencyValue,
      quantity: data.previewQuantity || ""
    }
  }

  dateText() {
    const value = this.effectiveOnTarget?.value
    if (!value) return this.previewDateTarget.dataset.placeholder

    const date = new Date(`${value}T12:00:00`)
    if (Number.isNaN(date.valueOf())) return this.previewDateTarget.dataset.placeholder

    return date.toLocaleDateString(document.documentElement.lang || "en", {
      day: "2-digit",
      month: "short",
      year: "numeric"
    })
  }

  previewFor(kind, instrument) {
    const panel = this.previewPanelTarget.dataset
    const current = this.parseDecimal(instrument.quantity)

    if (!current) return { copy: panel.quantityActionFormNoQuantityCopyValue, note: "" }

    const result = this.quantityResult(kind, current)
    if (!result) return { copy: "", note: "", current, result: null }

    const fractional = this.fractionalPart(result.quantity)
    const resultText = `${this.formatDecimal(result.quantity)}${fractional ? "*" : ""}`
    const note = fractional ? this.fractionalNote(fractional, panel) : ""

    return { copy: "", note, current: result.current, result: result.quantity, resultText, cashQuantity: result.cashQuantity }
  }

  fractionalNote(quantity, panel) {
    return (panel.quantityActionFormFractionalNoteValue ||
      "* %{quantity} fractional %{unit} may be paid in cash instead, depending on the issuer or broker.")
      .replace("%{quantity}", this.formatDecimal(quantity))
      .replace("%{unit}", this.unitLabel(quantity))
  }

  labelFor(kind) {
    const key = kind === "share_bonus" ? "quantityActionFormShareBonusLabelValue" :
      kind === "reverse_split" ? "quantityActionFormReverseSplitLabelValue" :
        "quantityActionFormStockSplitLabelValue"

    return this.previewPanelTarget.dataset[key] || kind.replaceAll("_", " ")
  }

  quantityResult(kind, current) {
    let adjusted
    if (kind === "share_bonus") {
      const percentage = this.parseDecimal(this.bonusPercentageTarget?.value)
      if (!percentage || percentage.digits <= 0n) return null

      const rate = this.divideDecimals(percentage, this.parseDecimal("100"), 12)
      adjusted = this.multiplyDecimals(current, this.addDecimals(this.parseDecimal("1"), rate))
    } else {
      const numerator = this.parseDecimal(this.ratioNumeratorTarget?.value)
      const denominator = this.parseDecimal(this.ratioDenominatorTarget?.value)
      if (!numerator || !denominator || numerator.scale > 0 || denominator.scale > 0 ||
        numerator.digits <= 0n || denominator.digits <= 0n) return null

      adjusted = this.divideDecimals(this.multiplyDecimals(current, numerator), denominator, 8)
    }

    const cashQuantity = this.parseDecimal(this.cashInLieuQuantityTarget?.value)
    if (cashQuantity && cashQuantity.digits < 0n) return null
    const quantity = cashQuantity && cashQuantity.digits > 0n
      ? this.addDecimals(adjusted, this.negateDecimal(cashQuantity))
      : adjusted
    if (quantity.digits < 0n) return null

    return { current, adjusted, quantity, cashQuantity: cashQuantity?.digits > 0n ? cashQuantity : null }
  }

  fractionalPart(decimal) {
    if (decimal.scale === 0) return null

    const factor = 10n ** BigInt(decimal.scale)
    const digits = (decimal.digits < 0n ? -decimal.digits : decimal.digits) % factor
    return digits === 0n ? null : this.normalizeDecimal({ digits, scale: decimal.scale })
  }

  parseDecimal(raw) {
    if (!raw) return null

    const match = String(raw).trim().match(/^([+-]?)(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:[eE]([+-]?\d+))?$/)
    if (!match) return null

    const [, sign, wholeDigits, fractionalDigits, leadingFractionDigits, exponentText] = match
    const fraction = fractionalDigits ?? leadingFractionDigits ?? ""
    const exponent = Number(exponentText || "0")
    if (!Number.isSafeInteger(exponent) || Math.abs(exponent) > 100) return null

    let digits = `${wholeDigits || ""}${fraction}`.replace(/^0+(?=\d)/, "") || "0"
    let scale = fraction.length - exponent
    if (scale < 0) {
      digits += "0".repeat(-scale)
      scale = 0
    }

    return this.normalizeDecimal({ digits: BigInt(`${sign === "-" ? "-" : ""}${digits}`), scale })
  }

  normalizeDecimal(decimal) {
    let { digits, scale } = decimal
    while (scale > 0 && digits % 10n === 0n) {
      digits /= 10n
      scale -= 1
    }
    return { digits, scale }
  }

  addDecimals(left, right) {
    const scale = Math.max(left.scale, right.scale)
    return this.normalizeDecimal({
      digits: left.digits * 10n ** BigInt(scale - left.scale) + right.digits * 10n ** BigInt(scale - right.scale),
      scale
    })
  }

  multiplyDecimals(left, right) {
    return this.normalizeDecimal({ digits: left.digits * right.digits, scale: left.scale + right.scale })
  }

  divideDecimals(left, right, scale) {
    if (!right || right.digits === 0n) return null

    const sign = left.digits < 0n === right.digits < 0n ? 1n : -1n
    const numerator = (left.digits < 0n ? -left.digits : left.digits) * 10n ** BigInt(right.scale + scale)
    const denominator = (right.digits < 0n ? -right.digits : right.digits) * 10n ** BigInt(left.scale)
    let digits = numerator / denominator
    if ((numerator % denominator) * 2n >= denominator) digits += 1n

    return this.normalizeDecimal({ digits: sign * digits, scale })
  }

  negateDecimal(decimal) {
    return { digits: -decimal.digits, scale: decimal.scale }
  }

  unitLabel(decimal) {
    return decimal?.digits === 1n && decimal.scale === 0 ? "share" : "shares"
  }

  formatDecimal(decimal) {
    const negative = decimal.digits < 0n
    const digits = (negative ? -decimal.digits : decimal.digits).toString().padStart(decimal.scale + 1, "0")
    const splitAt = digits.length - decimal.scale
    const whole = digits.slice(0, splitAt)
    const fraction = digits.slice(splitAt).replace(/0+$/, "")
    return `${negative && decimal.digits !== 0n ? "-" : ""}${whole}${fraction ? `.${fraction}` : ""}`
  }

  cashText(currency) {
    const raw = this.cashInLieuAmountTarget?.value?.trim()
    if (!raw) return "—"
    if (!currency) return raw

    const numeric = Number(raw.replace(",", "."))
    if (!Number.isFinite(numeric)) return `${currency} ${raw}`

    try {
      return new Intl.NumberFormat(document.documentElement.lang || "en", {
        style: "currency",
        currency,
        minimumFractionDigits: 2,
        maximumFractionDigits: 2
      }).format(numeric)
    } catch {
      return `${currency} ${raw}`
    }
  }
}
