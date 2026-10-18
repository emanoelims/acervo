import {Floating} from "./floating"

const element = (tag, className) => {
  const node = document.createElement(tag)
  if (className) node.className = className
  return node
}

// The native select owns form values and LiveView validation. The ignored
// picker owns presentation and uses the same Floating UI lifecycle as menus.
export const Select = {
  mounted() {
    this.native = document.getElementById(this.el.dataset.nativeSelect)
    this.control = this.el.closest('.field-select-control')
    this.label = document.getElementById(`${this.native.id}-label`)
    this.disclosure = element('details', 'popover select-popover')
    this.disclosure.dataset.popover = ''
    this.reference = element('summary', `${this.native.className} select-trigger`)
    this.reference.id = `${this.native.id}-trigger`
    this.reference.setAttribute('role', 'combobox')
    this.reference.setAttribute('aria-haspopup', 'listbox')
    this.reference.setAttribute('aria-expanded', 'false')
    this.reference.setAttribute('aria-controls', `${this.native.id}-options`)
    this.valueLabel = element('span', 'select-value')
    const chevron = element('span', 'lucide-thin-chevrons-down-up size-3.5')
    chevron.setAttribute('aria-hidden', 'true')
    this.reference.append(this.valueLabel, chevron)
    this.panel = element('div', 'floating-panel popover-panel dropdown-menu select-options')
    this.panel.id = `${this.native.id}-options`
    this.panel.setAttribute('role', 'listbox')
    const positioner = element('span')
    positioner.id = `${this.native.id}-positioner`
    positioner.hidden = true
    positioner.dataset.panel = this.panel.id
    positioner.dataset.placement = 'bottom-start'
    positioner.dataset.offset = '6'
    positioner.dataset.matchWidth = 'true'
    positioner.dataset.maxHeight = '288'
    this.disclosure.append(this.reference, positioner, this.panel)
    this.el.append(this.disclosure)
    this.floating = {...Floating, el: positioner}
    this.activateLabel = event => {
      event.preventDefault()
      if (this.native.disabled) return
      this.focus()
      this.disclosure.open = true
    }
    this.change = () => this.sync()
    this.focus = () => this.reference.focus({preventScroll: true})
    this.invalid = event => {event.preventDefault(); this.focus()}
    this.disabled = event => {
      if (!this.native.disabled) return
      event.preventDefault()
      event.stopImmediatePropagation()
    }
    this.choose = event => {
      const option = event.target.closest('button[role=option]')
      if (!option || option.disabled) return
      this.native.selectedIndex = Number(option.dataset.optionIndex)
      this.disclosure.open = false
      this.focus()
      this.native.dispatchEvent(new Event('input', {bubbles: true}))
      this.native.dispatchEvent(new Event('change', {bubbles: true}))
      this.sync()
    }
    this.label?.addEventListener('click', this.activateLabel)
    this.reference.addEventListener('click', this.disabled, true)
    this.reference.addEventListener('keydown', this.disabled, true)
    this.native.addEventListener('change', this.change)
    this.native.addEventListener('focus', this.focus)
    this.native.addEventListener('invalid', this.invalid)
    this.panel.addEventListener('click', this.choose)
    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.native, {attributes: true, childList: true, subtree: true, characterData: true})
    this.observer.observe(this.control, {attributes: true, attributeFilter: ['class']})
    this.sync()
    Floating.mounted.call(this.floating)
  },
  sync() {
    if (!this.control.classList.contains('is-enhanced')) this.control.classList.add('is-enhanced')
    if (this.native.tabIndex !== -1) this.native.tabIndex = -1
    if (this.native.getAttribute('aria-hidden') !== 'true') this.native.setAttribute('aria-hidden', 'true')
    if (this.native.disabled) this.disclosure.open = false
    const label = document.getElementById(`${this.native.id}-label`)
    const name = this.native.getAttribute('aria-label') || label?.textContent.trim() || this.native.name
    this.reference.setAttribute('aria-label', name)
    this.panel.setAttribute('aria-label', name)
    for (const attribute of ['aria-invalid', 'aria-describedby']) {
      const value = this.native.getAttribute(attribute)
      if (value) this.reference.setAttribute(attribute, value)
      else this.reference.removeAttribute(attribute)
    }
    this.reference.setAttribute('aria-disabled', String(this.native.disabled))
    this.reference.setAttribute('aria-required', String(this.native.required))
    this.reference.tabIndex = this.native.disabled ? -1 : 0
    this.reference.classList.toggle('field-invalid', this.native.getAttribute('aria-invalid') === 'true')
    this.valueLabel.textContent = this.native.selectedOptions[0]?.label || ''
    const options = Array.from(this.native.options)
    const signature = JSON.stringify(options.map(option => [option.label, option.value, option.selected, option.disabled, option.parentElement.label, option.parentElement.disabled]))
    if (signature === this.signature) return
    this.signature = signature
    const focusedIndex = this.panel.contains(document.activeElement) ? document.activeElement.dataset.optionIndex : null
    this.panel.replaceChildren()
    let group = null
    options.forEach((option, index) => {
      const parent = option.parentElement
      if (parent.tagName === 'OPTGROUP' && parent !== group) {
        group = parent
        const heading = element('div', 'dropdown-heading')
        heading.setAttribute('role', 'presentation')
        heading.textContent = parent.label
        this.panel.append(heading)
      }
      const button = element('button', 'dropdown-item select-option')
      button.type = 'button'
      button.tabIndex = -1
      button.dataset.optionIndex = String(index)
      button.setAttribute('role', 'option')
      button.setAttribute('aria-selected', String(option.selected))
      button.disabled = option.disabled || (parent.tagName === 'OPTGROUP' && parent.disabled)
      const text = element('span', 'dropdown-item-label')
      text.textContent = option.label
      const check = element('span', 'lucide-thin-check size-3.5')
      check.setAttribute('aria-hidden', 'true')
      check.style.visibility = option.selected ? 'visible' : 'hidden'
      button.append(text, check)
      this.panel.append(button)
      if (focusedIndex === String(index)) button.focus({preventScroll: true})
    })
    if (this.floating?.position && this.disclosure.open) this.floating.position()
  },
  updated() {this.sync()},
  destroyed() {
    Floating.destroyed.call(this.floating)
    this.observer.disconnect()
    this.label?.removeEventListener('click', this.activateLabel)
    this.native.removeEventListener('change', this.change)
    this.native.removeEventListener('focus', this.focus)
    this.native.removeEventListener('invalid', this.invalid)
    this.reference.removeEventListener('click', this.disabled, true)
    this.reference.removeEventListener('keydown', this.disabled, true)
    this.panel.removeEventListener('click', this.choose)
  }
}
