import { Controller } from "@hotwired/stimulus"

let nextId = 0
const validationFocusTimers = new WeakMap()

export default class extends Controller {
  connect() {
    this.native = this.element
    this.opened = false
    this.activeIndex = -1
    this.previousTabIndex = this.native.getAttribute("tabindex")
    this.previousAriaHidden = this.native.getAttribute("aria-hidden")
    this.previousAutofocus = this.native.autofocus
    this.shouldAutofocus = this.previousAutofocus || document.activeElement === this.native
    this.createControl()
    this.bindEvents()
    this.syncFromNative()

    if (this.shouldAutofocus && !this.button.disabled) this.button.focus()

    this.observer = new MutationObserver(() => this.syncFromNative())
    this.observer.observe(this.native, {
      attributes: true,
      attributeFilter: [ "disabled", "required", "aria-invalid" ],
      childList: true,
      subtree: true
    })
  }

  disconnect() {
    this.observer?.disconnect()
    this.unbindEvents()
    this.close({ focus: false })

    this.wrapper?.remove()

    this.native.classList.remove("caramelo-select-native")
    if (this.previousTabIndex === null) this.native.removeAttribute("tabindex")
    else this.native.setAttribute("tabindex", this.previousTabIndex)
    if (this.previousAriaHidden === null) this.native.removeAttribute("aria-hidden")
    else this.native.setAttribute("aria-hidden", this.previousAriaHidden)
    this.native.autofocus = this.previousAutofocus
    if (this.formLabel) this.formLabel.htmlFor = this.previousLabelFor
  }

  createControl() {
    const id = this.native.id || `caramelo-select-${++nextId}`
    this.native.id = id
    this.listboxId = `${id}-listbox`
    this.buttonId = `${id}-button`

    this.wrapper = document.createElement("div")
    this.wrapper.className = "caramelo-select"
    this.copySizingClasses()
    this.native.parentNode.insertBefore(this.wrapper, this.native)

    this.button = document.createElement("button")
    this.button.type = "button"
    this.button.id = this.buttonId
    this.button.className = "caramelo-select-trigger"
    this.button.setAttribute("role", "combobox")
    this.button.setAttribute("aria-haspopup", "listbox")
    this.button.setAttribute("aria-autocomplete", "none")
    this.button.setAttribute("aria-expanded", "false")
    this.button.setAttribute("aria-controls", this.listboxId)
    this.button.setAttribute("touch-action", "manipulation")

    this.valueLabel = document.createElement("span")
    this.valueLabel.id = `${id}-value`
    this.valueLabel.className = "caramelo-select-label"
    this.button.appendChild(this.valueLabel)

    const chevron = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    chevron.setAttribute("viewBox", "0 0 20 20")
    chevron.setAttribute("fill", "none")
    chevron.setAttribute("aria-hidden", "true")
    chevron.classList.add("caramelo-select-chevron")
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
    path.setAttribute("d", "m5 7.5 5 5 5-5")
    path.setAttribute("stroke", "currentColor")
    path.setAttribute("stroke-width", "1.75")
    path.setAttribute("stroke-linecap", "round")
    path.setAttribute("stroke-linejoin", "round")
    chevron.appendChild(path)
    this.button.appendChild(chevron)

    this.listbox = document.createElement("div")
    this.listbox.id = this.listboxId
    this.listbox.className = "caramelo-select-listbox"
    this.listbox.setAttribute("role", "listbox")
    this.listbox.setAttribute("aria-hidden", "true")
    this.listbox.hidden = true

    this.wrapper.append(this.button, this.listbox)
    this.validationError = document.createElement("p")
    this.validationError.id = `${id}-error`
    this.validationError.className = "caramelo-select-error"
    this.validationError.setAttribute("role", "alert")
    this.validationError.hidden = true
    this.validationError.textContent = this.native.dataset.carameloSelectRequiredMessage || "Please select an option."
    this.wrapper.appendChild(this.validationError)
    this.native.classList.add("caramelo-select-native")
    this.native.setAttribute("tabindex", "-1")
    this.native.setAttribute("aria-hidden", "true")

    const label = Array.from(document.querySelectorAll("label")).find(candidate => candidate.htmlFor === id)
    if (label) {
      this.formLabel = label
      this.previousLabelFor = label.htmlFor
      if (!label.id) label.id = `${id}-label`
      label.htmlFor = this.buttonId
      this.button.setAttribute("aria-labelledby", `${label.id} ${this.valueLabel.id}`)
      this.listbox.setAttribute("aria-labelledby", label.id)
    } else if (this.native.getAttribute("aria-label")) {
      this.button.setAttribute("aria-label", this.native.getAttribute("aria-label"))
      this.listbox.setAttribute("aria-label", this.native.getAttribute("aria-label"))
    }

    const describedBy = this.native.getAttribute("aria-describedby")
    this.button.setAttribute("aria-describedby", [ describedBy, this.validationError.id ].filter(Boolean).join(" "))
    this.button.autofocus = this.previousAutofocus
    this.native.autofocus = false
  }

  copySizingClasses() {
    const sizingClasses = Array.from(this.native.classList).filter(className =>
      /^(?:w-|min-w-|max-w-|sm:w-|sm:min-w-|sm:max-w-|md:w-|md:min-w-|md:max-w-|lg:w-|lg:min-w-|lg:max-w-|xl:w-|xl:min-w-|xl:max-w-)/.test(className)
    )
    this.wrapper.classList.add(...sizingClasses)
  }

  bindEvents() {
    this.handleButtonClick = () => this.toggle()
    this.handleButtonKeydown = event => this.keydown(event)
    this.handleOptionClick = event => {
      const option = event.target.closest("[role='option']")
      if (!option || !this.listbox.contains(option)) return
      this.choose(Number(option.dataset.index))
    }
    this.handleOutside = event => {
      if (this.opened && !this.wrapper.contains(event.target)) this.close({ focus: false })
    }
    this.handleNativeChange = () => this.syncFromNative()
    this.handleInvalid = event => {
      event.preventDefault()
      this.button.setAttribute("aria-invalid", "true")
      this.validationError.hidden = false
      // Chrome may focus a later native field while it finishes constraint validation.
      // Restore focus after that validation pass so the first invalid field remains clear.
      const form = this.native.form
      if (!form) {
        this.button.focus()
        return
      }

      if (!validationFocusTimers.has(form)) {
        const timer = window.setTimeout(() => {
          validationFocusTimers.delete(form)
          form.querySelector(".caramelo-select-trigger[aria-invalid='true']")?.focus()
        })
        validationFocusTimers.set(form, timer)
      }
    }

    this.button.addEventListener("click", this.handleButtonClick)
    this.button.addEventListener("keydown", this.handleButtonKeydown)
    this.listbox.addEventListener("click", this.handleOptionClick)
    this.native.addEventListener("change", this.handleNativeChange)
    this.native.addEventListener("invalid", this.handleInvalid, true)
    document.addEventListener("pointerdown", this.handleOutside)
  }

  unbindEvents() {
    this.button?.removeEventListener("click", this.handleButtonClick)
    this.button?.removeEventListener("keydown", this.handleButtonKeydown)
    this.listbox?.removeEventListener("click", this.handleOptionClick)
    this.native?.removeEventListener("change", this.handleNativeChange)
    this.native?.removeEventListener("invalid", this.handleInvalid, true)
    document.removeEventListener("pointerdown", this.handleOutside)
  }

  syncFromNative() {
    if (!this.native || !this.button) return

    this.options = Array.from(this.native.options)
    this.renderOptions()
    this.updateButton()
    this.syncDisabled()
    if (this.native.value) this.clearValidationError()

    if (this.opened) {
      const selectedIndex = this.selectedEnabledIndex()
      this.setActive(this.options[selectedIndex] ? selectedIndex : this.firstEnabledIndex())
    }
  }

  renderOptions() {
    this.listbox.replaceChildren()
    const available = this.options.filter(option => !option.disabled)

    if (available.length === 0) {
      const empty = document.createElement("p")
      empty.className = "caramelo-select-empty"
      empty.setAttribute("role", "status")
      empty.textContent = this.native.dataset.carameloSelectEmptyLabel || "No options available"
      this.listbox.appendChild(empty)
      this.activeIndex = -1
      return
    }

    this.options.forEach((option, index) => {
      const item = document.createElement("div")
      item.id = `${this.listboxId}-option-${index}`
      item.className = "caramelo-select-option"
      item.dataset.index = index
      item.setAttribute("role", "option")
      item.setAttribute("aria-selected", String(option.selected))
      item.tabIndex = -1

      const text = document.createElement("span")
      text.className = "caramelo-select-option-label"
      text.textContent = option.textContent.trim()
      item.appendChild(text)

      const check = document.createElement("span")
      check.className = "caramelo-select-option-check"
      check.setAttribute("aria-hidden", "true")
      check.textContent = option.selected ? "✓" : ""
      item.appendChild(check)

      if (option.disabled) {
        item.setAttribute("aria-disabled", "true")
        item.classList.add("caramelo-select-option-disabled")
      }

      this.listbox.appendChild(item)
    })
  }

  updateButton() {
    const selected = this.native.selectedOptions?.[0]
    this.valueLabel.textContent = selected?.textContent.trim() || this.native.dataset.placeholder || "Select…"

    const invalid = this.native.getAttribute("aria-invalid") || (this.native.classList.contains("ui-field-invalid") ? "true" : null)
    if (invalid) this.button.setAttribute("aria-invalid", invalid)
    else this.button.removeAttribute("aria-invalid")

    if (this.native.required) this.button.setAttribute("aria-required", "true")
    else this.button.removeAttribute("aria-required")
  }

  clearValidationError() {
    this.validationError.hidden = true
    if (this.native.getAttribute("aria-invalid") !== "true") this.button.removeAttribute("aria-invalid")
  }

  syncDisabled() {
    this.button.disabled = this.native.disabled
    this.button.setAttribute("aria-disabled", String(this.native.disabled))
    if (this.native.disabled && this.opened) this.close({ focus: false })
  }

  toggle() {
    if (this.opened) this.close()
    else this.open()
  }

  open(direction = 0) {
    if (this.native.disabled) return

    this.opened = true
    this.listbox.hidden = false
    this.listbox.setAttribute("aria-hidden", "false")
    this.button.setAttribute("aria-expanded", "true")
    this.wrapper.dataset.open = "true"

    const selected = this.selectedEnabledIndex()
    const index = direction > 0 ? this.nextEnabledIndex(selected, 1) :
      direction < 0 ? this.nextEnabledIndex(selected, -1) : selected
    this.setActive(index >= 0 ? index : this.firstEnabledIndex())
  }

  close({ focus = true } = {}) {
    if (!this.opened) return

    this.opened = false
    this.listbox.hidden = true
    this.listbox.setAttribute("aria-hidden", "true")
    this.button.setAttribute("aria-expanded", "false")
    this.button.removeAttribute("aria-activedescendant")
    delete this.wrapper.dataset.open
    this.activeIndex = -1
    this.listbox.querySelectorAll("[data-active='true']").forEach(option => delete option.dataset.active)

    if (focus) this.button.focus()
  }

  keydown(event) {
    const space = event.key === " " || event.key === "Spacebar"

    if (event.key === "Tab") {
      this.close({ focus: false })
      return
    }

    if (event.key === "Escape") {
      if (!this.opened) return
      event.preventDefault()
      this.close()
      return
    }

    if (event.key === "ArrowDown") {
      event.preventDefault()
      if (!this.opened) this.open(1)
      else this.move(1)
      return
    }

    if (event.key === "ArrowUp") {
      event.preventDefault()
      if (!this.opened) this.open(-1)
      else this.move(-1)
      return
    }

    if (event.key === "Home") {
      event.preventDefault()
      if (!this.opened) this.open()
      this.setActive(this.firstEnabledIndex())
      return
    }

    if (event.key === "End") {
      event.preventDefault()
      if (!this.opened) this.open()
      this.setActive(this.lastEnabledIndex())
      return
    }

    if (event.key === "Enter" || space) {
      event.preventDefault()
      if (!this.opened) this.open()
      else this.choose(this.activeIndex)
    }
  }

  move(step) {
    this.setActive(this.nextEnabledIndex(this.activeIndex, step))
  }

  choose(index) {
    const option = this.options[index]
    if (!option || option.disabled) return

    this.native.selectedIndex = index
    this.native.dispatchEvent(new Event("input", { bubbles: true }))
    this.native.dispatchEvent(new Event("change", { bubbles: true }))
    this.clearValidationError()
    this.button.setAttribute("aria-invalid", "false")
    this.close()
  }

  setActive(index) {
    this.activeIndex = index >= 0 ? index : -1
    this.listbox.querySelectorAll("[role='option']").forEach(option => {
      const active = Number(option.dataset.index) === this.activeIndex
      option.dataset.active = String(active)
    })

    const active = this.listbox.querySelector(`[data-index='${this.activeIndex}']`)
    if (active) {
      this.button.setAttribute("aria-activedescendant", active.id)
      active.scrollIntoView({ block: "nearest" })
    } else {
      this.button.removeAttribute("aria-activedescendant")
    }
  }

  selectedEnabledIndex() {
    const index = this.native.selectedIndex
    return this.options[index] && !this.options[index].disabled ? index : this.firstEnabledIndex()
  }

  firstEnabledIndex() {
    return this.options.findIndex(option => !option.disabled)
  }

  lastEnabledIndex() {
    for (let index = this.options.length - 1; index >= 0; index -= 1) {
      if (!this.options[index].disabled) return index
    }

    return -1
  }

  nextEnabledIndex(index, step) {
    const enabled = this.options.map((option, optionIndex) => option.disabled ? null : optionIndex).filter(index => index !== null)
    if (enabled.length === 0) return -1

    const current = enabled.indexOf(index)
    const position = current === -1 ? (step > 0 ? 0 : enabled.length - 1) : (current + step + enabled.length) % enabled.length
    return enabled[position]
  }
}
