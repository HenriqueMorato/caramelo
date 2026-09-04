import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["select", "picker", "input", "list", "option", "empty", "label"]

  connect() {
    this.selectTarget.hidden = true
    this.pickerTarget.hidden = false
    this.labelTarget.htmlFor = this.inputTarget.id
    this.restoreSelection()
    if (this.selectTarget.autofocus) this.inputTarget.focus()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  open() {
    this.inputTarget.select()
    this.filter("")
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.timer = null
      this.filter(this.inputTarget.value)
    }, 150)
  }

  filter(query) {
    const search = query.trim().toLocaleLowerCase()
    this.optionTargets.forEach(option => {
      option.hidden = !option.textContent.toLocaleLowerCase().includes(search)
    })
    this.listTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
    this.emptyTarget.hidden = this.visibleOptions.length > 0
    this.highlight(this.visibleOptions[0])
  }

  keydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    } else if (event.key === "Tab") {
      this.close()
    } else if (["ArrowDown", "ArrowUp"].includes(event.key)) {
      event.preventDefault()
      this.flushSearch()
      if (this.listTarget.hidden) this.filter("")
      const options = this.visibleOptions
      const index = options.indexOf(this.activeOption)
      const step = event.key === "ArrowDown" ? 1 : -1
      this.highlight(options[(index + step + options.length) % options.length])
    } else if (event.key === "Enter" && !this.listTarget.hidden) {
      event.preventDefault()
      this.flushSearch()
      if (this.activeOption) this.choose(this.activeOption)
    }
  }

  pick(event) {
    this.choose(event.currentTarget)
  }

  flushSearch() {
    if (this.timer) this.filter(this.inputTarget.value)
    clearTimeout(this.timer)
    this.timer = null
  }

  choose(option) {
    this.selectTarget.value = option.dataset.code
    this.selectTarget.dispatchEvent(new Event("change", { bubbles: true }))
    this.close()
  }

  outside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  close() {
    clearTimeout(this.timer)
    this.timer = null
    this.listTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.highlight(null)
    this.restoreSelection()
  }

  restoreSelection() {
    this.inputTarget.value = this.selectTarget.selectedOptions[0]?.textContent || ""
    this.optionTargets.forEach(option => {
      const selected = option.dataset.code === this.selectTarget.value
      option.setAttribute("aria-selected", String(selected))
      option.querySelector("[data-selected-check]").textContent = selected ? "✓" : ""
    })
  }

  highlight(option) {
    this.activeOption = option
    this.optionTargets.forEach(item => item.dataset.active = String(item === option))
    if (option) {
      this.inputTarget.setAttribute("aria-activedescendant", option.id)
      option.scrollIntoView({ block: "nearest" })
    } else {
      this.inputTarget.removeAttribute("aria-activedescendant")
    }
  }

  get visibleOptions() {
    return this.optionTargets.filter(option => !option.hidden)
  }
}
