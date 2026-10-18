import {autoUpdate, computePosition, flip, offset, shift, size} from "@floating-ui/dom"

// Shared popover behavior. LiveView owns content; disclosure state, focus,
// placement and entrance timing stay local to the browser.
export const Floating = {
  mounted() {
    this.disclosure = this.el.closest("details")
    this.reference = this.disclosure.querySelector("summary")
    this.panel = document.getElementById(this.el.dataset.panel)
    this.listbox = this.panel.getAttribute("role") === "listbox"
    this.menu = this.listbox || this.panel.getAttribute("role") === "menu"
    this.menuItems = () => Array.from(this.panel.querySelectorAll(this.listbox ? '[role="option"]' : '[role="menuitem"]')).filter(item => !item.hidden && !item.matches(':disabled,[aria-disabled="true"]'))
    this.focusMenu = edge => {
      const items = this.menuItems()
      const item = edge === "last" ? items.at(-1) : edge === "selected" ? items.find(item => item.getAttribute("aria-selected") === "true") || items[0] : items[0]
      item?.focus({preventScroll: true})
    }
    this.triggerKey = event => {
      if (!this.menu || !["ArrowDown", "ArrowUp", "Enter", " "].includes(event.key)) return
      event.preventDefault()
      if (this.disclosure.open && ["Enter", " "].includes(event.key)) {
        this.disclosure.open = false
        return
      }
      this.menuFocus = this.listbox ? "selected" : event.key === "ArrowUp" ? "last" : "first"
      if (this.disclosure.open) {
        this.focusMenu(this.menuFocus)
        this.menuFocus = null
      } else this.disclosure.open = true
    }
    this.sync = () => {
      if (this.open === this.disclosure.open) return
      this.open = this.disclosure.open
      this.reference.setAttribute("aria-expanded", String(this.open))
      this.panel.removeAttribute("data-positioned")
      if (this.open) {
        this.search = ""
        this.searchAt = 0
        if (this.menu) this.menuFocus ||= this.listbox ? "selected" : "first"
        document.querySelectorAll("details[data-popover][open]").forEach(other => {
          if (other !== this.disclosure && !other.contains(this.disclosure) && !this.disclosure.contains(other)) other.removeAttribute("open")
        })
      }
      this.cleanup?.()
      this.cleanup = null
      this.panel.style.visibility = "hidden"
      this.generation = (this.generation || 0) + 1
      if (this.disclosure.open) {
        this.cleanup = autoUpdate(this.reference, this.panel, () => this.position())
      }
    }
    // Observe the open attribute before the browser paints. The toggle event
    // can arrive after the first frame, briefly exposing the panel at (0, 0).
    this.disclosureObserver = new MutationObserver(this.sync)
    this.disclosureObserver.observe(this.disclosure, {attributes: true, attributeFilter: ["open"]})
    // LiveView may replace inline styles during a patch while the panel is open.
    this.observer = new MutationObserver(() => {
      if (this.disclosure.open && !this.panel.style.left) this.position()
    })
    this.observer.observe(this.panel, {attributes: true, attributeFilter: ["style"]})
    this.outside = event => {
      if (!this.disclosure.open || this.disclosure.contains(event.target)) return
      if (event.target === document.documentElement && document.documentElement.classList.contains("theme-swap")) return
      this.disclosure.removeAttribute("open")
    }
    this.key = event => {
      if (!this.disclosure.open || event.defaultPrevented) return
      const nested = event.target.closest?.("details[data-popover][open]")
      if (nested && nested !== this.disclosure && this.disclosure.contains(nested)) return
      if (this.menu && this.panel.contains(event.target)) {
        const items = this.menuItems()
        if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
          event.preventDefault()
          const at = items.indexOf(document.activeElement)
          const next = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1 :
            (at + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length
          items[next]?.focus({preventScroll: true})
          return
        }
        if (event.key === " " && event.target.closest('[role="menuitem"],[role="option"]')) {
          event.preventDefault()
          event.target.closest('[role="menuitem"],[role="option"]').click()
          return
        }
        if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
          const now = performance.now()
          this.search = now - (this.searchAt || 0) < 600 ? (this.search || "") + event.key : event.key
          this.searchAt = now
          const normalized = text => text.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLocaleLowerCase()
          const query = normalized(this.search)
          const start = items.indexOf(document.activeElement) + 1
          const match = items.map((_, i) => items[(start + i) % items.length]).find(item => normalized(item.textContent.trim()).startsWith(query))
          if (match) {event.preventDefault(); match.focus({preventScroll: true})}
          return
        }
        if (event.key === "Tab") {
          this.disclosure.open = false
          this.reference.focus({preventScroll: true})
          return
        }
      }
      if (event.key !== "Escape") return
      event.preventDefault()
      event.stopPropagation()
      this.disclosure.removeAttribute("open")
      this.reference.focus({preventScroll: true})
    }
    this.navigate = event => {
      if (event.target.closest("a[href]")) this.disclosure.removeAttribute("open")
    }
    this.reference.addEventListener("keydown", this.triggerKey)
    document.addEventListener("pointerdown", this.outside)
    document.addEventListener("keydown", this.key)
    this.panel.addEventListener("click", this.navigate)
    this.sync()
  },
  updated() {
    this.sync()
  },
  position() {
    const generation = this.generation
    computePosition(this.reference, this.panel, {
      strategy: "fixed",
      placement: this.el.dataset.placement || "bottom-start",
      middleware: [
        offset(({placement, rects}) => {
          // A wrapping toolbar's menus open below all of its rows.
          const bar = this.reference.closest('[data-popover-bar]')
          const edge = bar && placement.startsWith('bottom') ?
            Math.max(0, bar.getBoundingClientRect().bottom - rects.reference.y - rects.reference.height) : 0
          return Number(this.el.dataset.offset || 12) + edge
        }),
        flip({padding: 12}),
        shift({padding: 12}),
        size({padding: 12, apply: ({availableHeight, availableWidth, rects, elements}) => {
          const limit = Number(this.el.dataset.maxHeight) || availableHeight
          elements.floating.style.maxHeight = `${Math.max(0, Math.min(limit, availableHeight))}px`
          if (this.el.dataset.matchWidth === "true") elements.floating.style.width = `${Math.min(rects.reference.width, availableWidth)}px`
        }})
      ]
    }).then(({x, y, placement}) => {
      if (generation !== this.generation || !this.disclosure.open || !this.el.isConnected) return
      Object.assign(this.panel.style, {left: `${x}px`, top: `${y}px`, visibility: "visible"})
      this.panel.dataset.placement = placement
      this.panel.setAttribute("data-positioned", "")
      if (this.menuFocus) {
        this.focusMenu(this.menuFocus)
        this.menuFocus = null
      }
    })
  },
  destroyed() {
    this.generation++
    this.cleanup?.()
    this.observer.disconnect()
    this.disclosureObserver.disconnect()
    this.reference.removeEventListener("keydown", this.triggerKey)
    document.removeEventListener("pointerdown", this.outside)
    document.removeEventListener("keydown", this.key)
    this.panel.removeEventListener("click", this.navigate)
  }
}
