import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "instrument", "field", "select", "hidden" ]
  static values = { institutions: Object, institution: Number, noInstitution: String }

  connect() {
    this.selections = new Map()
    this.currentInstrumentId = null
    this.initialInstrumentId = String(this.instrumentTarget.value)
    this.sync()
  }

  sync() {
    if (this.currentInstrumentId !== null && !this.selectTarget.disabled) {
      this.selections.set(this.currentInstrumentId, this.selectTarget.value)
    }

    const instrumentId = String(this.instrumentTarget.value)
    const entries = this.institutionsValue[instrumentId] || []
    const hasChoice = entries.length > 1
    const hasSingleInstitution = entries.length === 1

    this.fieldTarget.hidden = !hasChoice
    this.selectTarget.disabled = !hasChoice
    this.hiddenTarget.disabled = !hasSingleInstitution
    this.hiddenTarget.value = hasSingleInstitution ? entries[0].id : ""
    this.currentInstrumentId = instrumentId

    if (!hasChoice) return

    const selected = this.selections.has(instrumentId) ?
      this.selections.get(instrumentId) :
      (instrumentId === this.initialInstrumentId ? String(this.institutionValue || "") : "")
    this.selectTarget.replaceChildren(new Option(this.noInstitutionValue, ""))
    entries.forEach(({ id, name }) => this.selectTarget.add(new Option(name, id)))
    if (entries.some(({ id }) => String(id) === selected)) this.selectTarget.value = selected
  }

  remember() {
    this.selections.set(this.currentInstrumentId, this.selectTarget.value)
  }
}
