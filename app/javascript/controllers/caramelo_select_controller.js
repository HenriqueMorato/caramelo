import { Controller } from "@hotwired/stimulus"

let nextId = 0
const validationFocusTimers = new WeakMap()

export default class extends Controller {
  connect() {
    this.native = this.element
    this.opened = false
    this.activeIndex = -1
    this.searchQuery = ""
    this.searchTimer = null
    this.validationInvalid = false
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
      attributeFilter: [ "aria-label", "aria-labelledby", "aria-invalid", "disabled", "hidden", "required" ],
      childList: true,
      subtree: true
    })
  }

  disconnect() {
    this.observer?.disconnect()
    this.unbindEvents()
    this.clearSearchTimer()
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

    this.searchable = this.native.dataset.carameloSelectSearch === "true"
    if (this.searchable) {
      this.wrapper.dataset.searchable = "true"
      this.searchInput = document.createElement("input")
      this.searchInput.id = `${id}-search`
      this.searchInput.type = "search"
      this.searchInput.className = "caramelo-select-search"
      this.searchLabel = this.native.dataset.carameloSelectSearchLabel || "Search options…"
      this.searchInput.placeholder = this.searchLabel
      this.searchInput.setAttribute("aria-autocomplete", "list")
      this.searchInput.setAttribute("aria-controls", this.listboxId)
      this.searchInput.setAttribute("aria-expanded", "false")
      this.searchInput.autocomplete = "off"
      this.searchInput.spellcheck = false
      this.searchInput.inputMode = "search"
      this.searchInput.hidden = true
      this.searchHint = document.createElement("span")
      this.searchHint.id = `${id}-search-hint`
      this.searchHint.className = "sr-only"
      this.searchHint.textContent = this.searchLabel
      this.searchHint.hidden = true
      this.searchInput.setAttribute("aria-describedby", this.searchHint.id)
    }

    this.wrapper.append(this.button)
    if (this.searchInput) this.wrapper.append(this.searchInput)
    if (this.searchHint) this.wrapper.append(this.searchHint)
    this.wrapper.append(this.listbox)
    this.noResults = document.createElement("p")
    this.noResults.id = `${id}-no-results`
    this.noResults.className = "caramelo-select-empty"
    this.noResults.setAttribute("role", "status")
    this.noResults.hidden = true
    this.wrapper.append(this.noResults)
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
      this.fallbackButtonLabelledBy = `${label.id} ${this.valueLabel.id}`
      this.fallbackListboxLabelledBy = label.id
    }

    this.originalDescribedBy = this.native.getAttribute("aria-describedby")
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
      if (!this.opened || this.wrapper.contains(event.target)) return

      const restoreFocus = !this.isFocusableTarget(event.target)
      this.close({ focus: false })
      if (restoreFocus) window.setTimeout(() => this.button.focus())
    }
    this.handleNativeChange = () => this.syncFromNative()
    this.handleSearchInput = event => {
      // Search text is transient UI state, not a form edit.
      event.stopPropagation()
      this.scheduleSearch()
    }
    this.handleSearchChange = event => event.stopPropagation()
    this.handleSearchKeydown = event => this.searchKeydown(event)
    this.handleInvalid = event => {
      event.preventDefault()
      this.validationInvalid = true
      this.validationError.hidden = false
      this.syncOwnerState()
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
          form.querySelector(".caramelo-select-trigger[aria-invalid='true'], input[role='combobox'][aria-invalid='true']")?.focus()
        })
        validationFocusTimers.set(form, timer)
      }
    }

    this.button.addEventListener("click", this.handleButtonClick)
    this.button.addEventListener("keydown", this.handleButtonKeydown)
    this.listbox.addEventListener("click", this.handleOptionClick)
    this.native.addEventListener("change", this.handleNativeChange)
    this.native.addEventListener("input", this.handleNativeChange)
    this.native.addEventListener("invalid", this.handleInvalid, true)
    this.searchInput?.addEventListener("input", this.handleSearchInput)
    this.searchInput?.addEventListener("change", this.handleSearchChange)
    this.searchInput?.addEventListener("keydown", this.handleSearchKeydown)
    document.addEventListener("pointerdown", this.handleOutside)
  }

  unbindEvents() {
    this.button?.removeEventListener("click", this.handleButtonClick)
    this.button?.removeEventListener("keydown", this.handleButtonKeydown)
    this.listbox?.removeEventListener("click", this.handleOptionClick)
    this.native?.removeEventListener("change", this.handleNativeChange)
    this.native?.removeEventListener("input", this.handleNativeChange)
    this.native?.removeEventListener("invalid", this.handleInvalid, true)
    this.searchInput?.removeEventListener("input", this.handleSearchInput)
    this.searchInput?.removeEventListener("change", this.handleSearchChange)
    this.searchInput?.removeEventListener("keydown", this.handleSearchKeydown)
    document.removeEventListener("pointerdown", this.handleOutside)
  }

  syncFromNative() {
    if (!this.native || !this.button) return

    this.syncNativeVisibility()
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
    this.noResults.hidden = true
    this.listbox.hidden = !this.opened
    this.listbox.setAttribute("aria-hidden", String(!this.opened))
    const available = this.options.filter(option => this.isSelectable(option))
    const matching = this.options.filter(option => this.isSelectable(option) && this.matchesSearch(option))

    if (available.length === 0) {
      this.showEmptyState(this.native.dataset.carameloSelectEmptyLabel || "No options available")
      this.activeIndex = -1
      return
    }

    if (matching.filter(option => !option.disabled).length === 0) {
      this.showEmptyState(this.native.dataset.carameloSelectNoResultsLabel || "No matching options")
      this.activeIndex = -1
      return
    }

    this.options.forEach((option, index) => {
      if (option.hidden) return

      const item = document.createElement("div")
      item.id = `${this.listboxId}-option-${index}`
      item.className = "caramelo-select-option"
      item.dataset.index = index
      item.setAttribute("role", "option")
      item.setAttribute("aria-selected", String(option.selected))
      item.tabIndex = -1
      item.hidden = !this.matchesSearch(option)

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
    this.syncOwnerState()
  }

  showEmptyState(message) {
    this.noResults.textContent = message
    this.listbox.hidden = true
    this.listbox.setAttribute("aria-hidden", "true")
    this.noResults.hidden = !this.opened
    this.syncOwnerState()
  }

  updateButton() {
    const selected = this.native.selectedOptions?.[0]
    this.valueLabel.textContent = selected?.textContent.trim() || this.native.dataset.placeholder || "Select…"
    this.syncOwnerState()
  }

  clearValidationError() {
    this.validationError.hidden = true
    this.validationInvalid = false
    this.syncOwnerState()
  }

  scheduleSearch() {
    this.clearSearchTimer()
    this.searchQuery = this.searchInput.value.trim().toLocaleLowerCase()
    this.searchTimer = window.setTimeout(() => {
      this.searchTimer = null
      this.renderOptions()
      this.setActive(this.firstEnabledIndex())
    }, 120)
  }

  flushSearch() {
    if (!this.searchInput || this.searchTimer === null) return

    this.clearSearchTimer()
    this.renderOptions()
    this.setActive(this.firstEnabledIndex())
  }

  clearSearchTimer() {
    if (this.searchTimer === null) return

    window.clearTimeout(this.searchTimer)
    this.searchTimer = null
  }

  matchesSearch(option) {
    return !this.searchQuery || option.textContent.trim().toLocaleLowerCase().includes(this.searchQuery)
  }

  isSelectable(option) {
    return !option.disabled && !option.hidden
  }

  syncDisabled() {
    const activeElement = document.activeElement
    const restoreFocus = this.native.disabled && this.wrapper.contains(activeElement)
    this.button.disabled = this.native.disabled
    this.button.setAttribute("aria-disabled", String(this.native.disabled))
    if (this.native.disabled) {
      if (this.opened) this.close({ focus: false })
      if (restoreFocus) this.focusNextControl()
    }
  }

  syncNativeVisibility() {
    const activeElement = document.activeElement
    const restoreFocus = this.native.hidden && this.wrapper.contains(activeElement)
    this.wrapper.hidden = this.native.hidden
    if (this.native.hidden) {
      if (this.opened) this.close({ focus: false })
      if (restoreFocus) this.focusNextControl()
    }
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
    if (this.searchInput) {
      this.activateSearchOwner()
      this.searchInput.hidden = false
      this.searchHint.hidden = false
      this.searchInput.value = this.searchQuery
      this.syncOwnerState()
    }
    this.wrapper.dataset.open = "true"

    this.renderOptions()
    const selected = this.selectedEnabledIndex()
    const index = direction > 0 ? this.nextEnabledIndex(selected, 1) :
      direction < 0 ? this.nextEnabledIndex(selected, -1) : selected
    this.setActive(index >= 0 ? index : this.firstEnabledIndex())
    if (this.searchInput) this.searchInput.focus()
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
    this.noResults.hidden = true
    if (this.searchInput) {
      this.clearSearchTimer()
      this.searchQuery = ""
      this.searchInput.value = ""
      this.searchInput.hidden = true
      this.searchHint.hidden = true
      this.searchInput.removeAttribute("aria-activedescendant")
      this.restoreButtonOwner()
      this.syncOwnerState()
      this.renderOptions()
    } else this.syncOwnerState()

    if (focus) this.button.focus()
  }

  keydown(event) {
    const space = event.key === " " || event.key === "Spacebar"

    if (event.key === "Tab") {
      if (this.searchInput && !this.searchInput.hidden) {
        event.preventDefault()
        this.close()
      } else {
        this.close({ focus: false })
      }
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

  searchKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
      return
    }

    if (event.key === "Tab") {
      event.preventDefault()
      this.close()
      return
    }

    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.flushSearch()
      this.move(event.key === "ArrowDown" ? 1 : -1)
      return
    }

    if (event.key === "Home" || event.key === "End") {
      this.flushSearch()
      return
    }

    if (event.key === "Enter") {
      event.preventDefault()
      this.flushSearch()
      this.choose(this.activeIndex)
    }
  }

  move(step) {
    this.setActive(this.nextEnabledIndex(this.activeIndex, step))
  }

  choose(index) {
    const option = this.options[index]
    if (!option || !this.isSelectable(option) || !this.matchesSearch(option)) return

    this.native.selectedIndex = index
    this.native.dispatchEvent(new Event("input", { bubbles: true }))
    this.native.dispatchEvent(new Event("change", { bubbles: true }))
    this.clearValidationError()
    this.close()
  }

  setActive(index) {
    this.activeIndex = index >= 0 ? index : -1
    this.listbox.querySelectorAll("[role='option']").forEach(option => {
      const active = Number(option.dataset.index) === this.activeIndex
      option.dataset.active = String(active)
    })

    const active = this.listbox.querySelector(`[data-index='${this.activeIndex}']`)
    this.button.removeAttribute("aria-activedescendant")
    this.searchInput?.removeAttribute("aria-activedescendant")
    if (active && !active.hidden) {
      const activeOwner = this.searchInput && !this.searchInput.hidden ? this.searchInput : this.button
      activeOwner.setAttribute("aria-activedescendant", active.id)
      active.scrollIntoView({ block: "nearest" })
    }
  }

  activateSearchOwner() {
    this.button.removeAttribute("role")
    this.button.removeAttribute("aria-autocomplete")
    this.button.removeAttribute("aria-expanded")
    this.button.removeAttribute("aria-controls")
    this.searchInput.setAttribute("role", "combobox")
    this.searchInput.setAttribute("aria-expanded", "true")
  }

  restoreButtonOwner() {
    this.searchInput.removeAttribute("role")
    this.searchInput.removeAttribute("aria-expanded")
    this.button.setAttribute("role", "combobox")
    this.button.setAttribute("aria-autocomplete", "none")
    this.button.setAttribute("aria-expanded", "false")
    this.button.setAttribute("aria-controls", this.listboxId)
  }

  syncOwnerState() {
    this.syncAccessibleNames()
    const activeOwner = this.searchInput && !this.searchInput.hidden ? this.searchInput : this.button
    const inactiveOwner = activeOwner === this.button ? this.searchInput : this.button
    const invalid = this.native.getAttribute("aria-invalid") ||
      (this.native.classList.contains("ui-field-invalid") || this.validationInvalid ? "true" : null)
    const describedBy = [
      this.originalDescribedBy,
      this.validationError?.id,
      activeOwner === this.searchInput && !this.searchHint.hidden ? this.searchHint.id : null,
      !this.noResults.hidden ? this.noResults.id : null
    ].filter(Boolean).join(" ")

    if (this.native.required) activeOwner.setAttribute("aria-required", "true")
    else activeOwner.removeAttribute("aria-required")
    if (invalid) activeOwner.setAttribute("aria-invalid", invalid)
    else activeOwner.removeAttribute("aria-invalid")
    if (describedBy) activeOwner.setAttribute("aria-describedby", describedBy)
    else activeOwner.removeAttribute("aria-describedby")
    activeOwner.setAttribute("aria-disabled", String(this.native.disabled))

    if (!inactiveOwner) return

    inactiveOwner.removeAttribute("aria-required")
    inactiveOwner.removeAttribute("aria-invalid")
    inactiveOwner.removeAttribute("aria-describedby")
    inactiveOwner.setAttribute("aria-disabled", String(this.native.disabled))
  }

  selectedEnabledIndex() {
    const index = this.native.selectedIndex
    return this.options[index] && this.isSelectable(this.options[index]) && this.matchesSearch(this.options[index]) ? index : this.firstEnabledIndex()
  }

  firstEnabledIndex() {
    return this.options.findIndex(option => this.isSelectable(option) && this.matchesSearch(option))
  }

  lastEnabledIndex() {
    for (let index = this.options.length - 1; index >= 0; index -= 1) {
      if (this.isSelectable(this.options[index]) && this.matchesSearch(this.options[index])) return index
    }

    return -1
  }

  nextEnabledIndex(index, step) {
    const enabled = this.options.map((option, optionIndex) => !this.isSelectable(option) || !this.matchesSearch(option) ? null : optionIndex).filter(index => index !== null)
    if (enabled.length === 0) return -1

    const current = enabled.indexOf(index)
    const position = current === -1 ? (step > 0 ? 0 : enabled.length - 1) : (current + step + enabled.length) % enabled.length
    return enabled[position]
  }

  syncAccessibleNames() {
    const nativeLabelledBy = this.native.getAttribute("aria-labelledby")
    const nativeAriaLabel = this.native.getAttribute("aria-label")

    if (nativeLabelledBy) {
      this.button.setAttribute("aria-labelledby", nativeLabelledBy)
      this.listbox.setAttribute("aria-labelledby", nativeLabelledBy)
      this.button.removeAttribute("aria-label")
      this.listbox.removeAttribute("aria-label")
      this.searchInput?.setAttribute("aria-labelledby", nativeLabelledBy)
      this.searchInput?.removeAttribute("aria-label")
    } else if (nativeAriaLabel) {
      this.button.removeAttribute("aria-labelledby")
      this.listbox.removeAttribute("aria-labelledby")
      this.button.setAttribute("aria-label", nativeAriaLabel)
      this.listbox.setAttribute("aria-label", nativeAriaLabel)
      this.searchInput?.removeAttribute("aria-labelledby")
      this.searchInput?.setAttribute("aria-label", `${nativeAriaLabel} — ${this.searchLabel}`)
    } else {
      const buttonLabelledBy = this.fallbackButtonLabelledBy
      const listboxLabelledBy = this.fallbackListboxLabelledBy
      if (buttonLabelledBy) this.button.setAttribute("aria-labelledby", buttonLabelledBy)
      else this.button.removeAttribute("aria-labelledby")
      if (listboxLabelledBy) this.listbox.setAttribute("aria-labelledby", listboxLabelledBy)
      else this.listbox.removeAttribute("aria-labelledby")
      this.button.removeAttribute("aria-label")
      this.listbox.removeAttribute("aria-label")
      if (this.searchInput) {
        if (listboxLabelledBy) this.searchInput.setAttribute("aria-labelledby", listboxLabelledBy)
        else this.searchInput.removeAttribute("aria-labelledby")
        if (listboxLabelledBy) this.searchInput.removeAttribute("aria-label")
        else this.searchInput.setAttribute("aria-label", this.searchLabel)
      }
    }
  }

  isFocusableTarget(target) {
    const element = target instanceof Element ? target : target?.parentElement
    return Boolean(element?.closest("a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), summary, [tabindex]:not([tabindex='-1'])"))
  }

  focusNextControl() {
    const elements = Array.from(this.native.form?.elements || [])
    const currentIndex = elements.indexOf(this.native)
    const isFocusable = element => !element.disabled && !element.hidden && element.type !== "hidden" && element.tabIndex >= 0 && element.getClientRects().length > 0
    const next = elements.slice(currentIndex + 1).find(isFocusable)
    const previous = elements.slice(0, currentIndex).reverse().find(isFocusable)
    const fallback = document.querySelector("main button:not(:disabled), main input:not(:disabled), main select:not(:disabled), main textarea:not(:disabled), main a[href]")

    ;(next || previous || fallback)?.focus()
  }
}
