import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "instrument",
    "currency",
    "fees",
    "institution",
    "side",
    "tradedOn",
    "quantity",
    "unitPrice",
    "settlement",
    "settlementRate",
    "settlementDirection",
    "receiptAsset",
    "receiptInstrument",
    "receiptMark",
    "receiptDate",
    "receiptSide",
    "receiptQuantity",
    "receiptPrice",
    "receiptFees",
    "receiptTotal"
  ]
  static values = { reportingCurrency: String }

  connect() {
    this.syncCurrency()
    this.syncSettlement()
    this.refreshReceipt()
  }

  syncCurrency(event) {
    if (!this.hasInstrumentTarget || !this.hasCurrencyTarget) {
      this.syncSettlement()
      this.refreshReceipt()
      return
    }

    const option = this.instrumentTarget.selectedOptions[0]
    this.currencyTarget.value = option?.dataset.currency || ""

    if (event && this.hasSettlementRateTarget) this.settlementRateTarget.value = ""

    if (option?.dataset.subunit && this.hasFeesTarget) {
      const step = 1 / Number(option.dataset.subunit)
      this.feesTarget.step = step
    }

    if (event && this.hasInstitutionTarget) {
      this.institutionTarget.value = option?.dataset.lastInstitutionId || ""
      this.institutionTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }

    this.syncSettlement()
    this.refreshReceipt()
  }

  syncSettlement() {
    if (!this.hasSettlementTarget) return

    if (!this.hasCurrencyTarget) return

    const nativeCurrency = this.currencyTarget.value
    const foreign = Boolean(nativeCurrency) && nativeCurrency !== this.reportingCurrencyValue
    this.settlementTarget.hidden = !foreign

    if (this.hasSettlementDirectionTarget) {
      this.settlementDirectionTarget.textContent = `1 ${nativeCurrency} = … ${this.reportingCurrencyValue}`
    }
  }

  resetReceipt() {
    window.setTimeout(() => this.refreshReceipt(), 0)
  }

  refreshReceipt() {
    if (!this.hasReceiptSideTarget) return

    const side = this.sideTargets.find((input) => input.checked)?.value || "buy"
    const quantity = this.valueFor("quantity")
    const unitPrice = this.valueFor("unitPrice")
    const fees = this.valueFor("fees")
    const currency = this.hasCurrencyTarget ? this.currencyTarget.value : ""
    const instrument = this.hasInstrumentTarget ? this.instrumentTarget.selectedOptions[0] : null
    const fractionDigits = this.currencyFractionDigits(currency, instrument)

    if (this.hasInstrumentTarget && this.hasReceiptAssetTarget) {
      this.receiptAssetTarget.textContent = instrument?.dataset.receiptLabel || this.receiptAssetTarget.dataset.placeholder
    }

    if (this.hasInstrumentTarget && this.hasReceiptInstrumentTarget) {
      this.receiptInstrumentTarget.textContent = instrument?.dataset.receiptName || this.receiptInstrumentTarget.dataset.placeholder
    }

    if (this.hasInstrumentTarget && this.hasReceiptMarkTarget) {
      this.receiptMarkTarget.textContent = instrument?.dataset.receiptTicker || this.receiptMarkTarget.dataset.placeholder
    }

    if (this.hasReceiptDateTarget) {
      const formattedDate = this.hasTradedOnTarget && this.tradedOnTarget.value
        ? this.formatDate(this.tradedOnTarget.value)
        : null
      this.receiptDateTarget.textContent = formattedDate || this.receiptDateTarget.dataset.placeholder
    }

    this.receiptSideTarget.textContent = side.toUpperCase()
    this.receiptSideTarget.classList.toggle("trade-receipt-side--sell", side === "sell")

    if (this.hasReceiptQuantityTarget) {
      this.receiptQuantityTarget.textContent = quantity.present
        ? this.formatQuantity(quantity.value)
        : this.receiptQuantityTarget.dataset.placeholder
    }

    if (this.hasReceiptPriceTarget) {
      this.receiptPriceTarget.textContent = unitPrice.present && currency
        ? this.formatMoney(unitPrice.value, currency, Math.max(8, fractionDigits), fractionDigits)
        : this.receiptPriceTarget.dataset.placeholder
    }

    if (this.hasReceiptFeesTarget) {
      this.receiptFeesTarget.textContent = currency && (fees.present || fees.empty)
        ? this.formatMoney(fees.value, currency, fractionDigits, fractionDigits)
        : this.receiptFeesTarget.dataset.placeholder
    }

    if (this.hasReceiptTotalTarget) {
      const total = quantity.present && unitPrice.present
        ? this.addDecimals(
          this.multiplyDecimals(quantity.value, unitPrice.value),
          side === "buy" ? fees.value : this.negateDecimal(fees.value)
        )
        : null
      this.receiptTotalTarget.textContent = total === null || !currency
        ? this.receiptTotalTarget.dataset.placeholder
        : this.formatMoney(total, currency, fractionDigits, fractionDigits)
    }
  }

  valueFor(targetName) {
    const target = this[`${targetName}Target`]
    const raw = target?.value?.trim() || ""
    const value = this.parseDecimal(raw)

    return {
      empty: raw === "",
      present: raw !== "" && value !== null,
      value: value || this.zeroDecimal()
    }
  }

  formatDate(value) {
    const date = new Date(`${value}T12:00:00`)
    return Number.isNaN(date.valueOf()) ? null : date.toLocaleDateString(document.documentElement.lang || "en", {
      day: "2-digit",
      month: "short",
      year: "numeric"
    })
  }

  formatQuantity(value) {
    return this.formatNumber(value, {
      maximumFractionDigits: 8
    })
  }

  formatMoney(value, currency, maximumFractionDigits, minimumFractionDigits = 0) {
    try {
      return new Intl.NumberFormat(document.documentElement.lang || "en", {
        style: "currency",
        currency,
        minimumFractionDigits,
        maximumFractionDigits
      }).format(this.decimalToString(value))
    } catch {
      return `${currency} ${this.decimalToString(value)}`
    }
  }

  formatNumber(value, options) {
    try {
      return new Intl.NumberFormat(document.documentElement.lang || "en", options)
        .format(this.decimalToString(value))
    } catch {
      return this.decimalToString(value)
    }
  }

  currencyFractionDigits(currency, instrument) {
    const dataValue = Number(instrument?.dataset.fractionDigits)
    if (Number.isInteger(dataValue) && dataValue >= 0) return dataValue

    try {
      return new Intl.NumberFormat(document.documentElement.lang || "en", {
        style: "currency",
        currency
      }).resolvedOptions().minimumFractionDigits
    } catch {
      return 2
    }
  }

  parseDecimal(raw) {
    if (!raw) return null

    const match = raw.match(/^([+-]?)(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:[eE]([+-]?\d+))?$/)
    if (!match) return null

    const [, sign, wholeDigits, fractionalDigits, leadingFractionDigits, exponentText] = match
    const whole = wholeDigits || ""
    const fraction = fractionalDigits ?? leadingFractionDigits ?? ""
    const exponent = Number(exponentText || "0")
    if (!Number.isSafeInteger(exponent) || Math.abs(exponent) > 100) return null

    let digits = `${whole}${fraction}`.replace(/^0+(?=\d)/, "") || "0"
    let scale = fraction.length - exponent
    if (scale < 0) {
      digits += "0".repeat(-scale)
      scale = 0
    }

    return this.normalizeDecimal({
      digits: BigInt(`${sign === "-" ? "-" : ""}${digits}`),
      scale
    })
  }

  zeroDecimal() {
    return { digits: 0n, scale: 0 }
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
    const leftDigits = left.digits * 10n ** BigInt(scale - left.scale)
    const rightDigits = right.digits * 10n ** BigInt(scale - right.scale)
    return this.normalizeDecimal({ digits: leftDigits + rightDigits, scale })
  }

  multiplyDecimals(left, right) {
    return this.normalizeDecimal({ digits: left.digits * right.digits, scale: left.scale + right.scale })
  }

  negateDecimal(decimal) {
    return { digits: -decimal.digits, scale: decimal.scale }
  }

  decimalToString(decimal) {
    const negative = decimal.digits < 0n
    const digits = (negative ? -decimal.digits : decimal.digits).toString().padStart(decimal.scale + 1, "0")
    const splitAt = digits.length - decimal.scale
    const whole = digits.slice(0, splitAt)
    const fraction = digits.slice(splitAt).replace(/0+$/, "")
    const sign = negative && decimal.digits !== 0n ? "-" : ""

    return `${sign}${whole}${fraction ? `.${fraction}` : ""}`
  }
}
