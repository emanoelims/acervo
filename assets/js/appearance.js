// Theme, accent and font are per-browser preferences (like leitor). The server
// renders the defaults on <html>, so default users never see a flash.
const KEY = 'acervo:appearance'
const OPTIONS = {
  theme: ['auto', 'studio', 'light', 'sepia', 'snow', 'dark', 'ink'],
  accent: ['vermilion', 'cobalt', 'moss', 'graphite'],
  font: ['inter', 'schibsted', 'atkinson', 'newsreader'],
}
const DEFAULTS = {theme: 'auto', accent: 'graphite', font: 'inter'}
const system = matchMedia('(prefers-color-scheme: dark)')
let state = {...DEFAULTS}
let swap = null

const resolved = theme => theme === 'auto' ? (system.matches ? 'dark' : 'studio') : theme
const read = () => {
  try {
    const value = JSON.parse(localStorage.getItem(KEY) || '{}')
    return value && typeof value === 'object' ? value : {}
  } catch (_) {return {}}
}
const valid = prefs => Object.fromEntries(Object.entries(DEFAULTS).map(([k, d]) =>
  [k, OPTIONS[k].includes(prefs[k]) ? prefs[k] : d]))

const apply = next => {
  state = next
  const root = document.documentElement
  root.dataset.themeMode = state.theme
  root.dataset.theme = resolved(state.theme)
  root.dataset.accent = state.accent
  root.dataset.font = state.font
  try {localStorage.setItem(KEY, JSON.stringify(state))} catch (_) {}
  window.dispatchEvent(new CustomEvent('acervo:appearance-changed', {detail: {...state}}))
}

export const appearance = () => ({...state})

export const initializeAppearance = () => {
  apply(valid(read()))
  system.addEventListener('change', () => {if (state.theme === 'auto') apply(state)})
  window.addEventListener('acervo:appearance', ({detail, target}) => {
    if (!detail) return
    setAppearance(detail.key, detail.value, target?.closest?.('button'))
  })
}

export const setAppearance = (key, value, origin) => {
  if (!OPTIONS[key]?.includes(value)) return
  const next = {...state, [key]: value}
  const root = document.documentElement
  if (key !== 'theme' || !document.startViewTransition || !origin ||
      matchMedia('(prefers-reduced-motion: reduce)').matches || resolved(value) === root.dataset.theme) {
    swap?.skipTransition()
    apply(next)
    return
  }
  const rect = origin.getBoundingClientRect(), w = innerWidth, h = innerHeight
  const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2
  const at = `${(x / w * 100).toFixed(2)}% ${(y / h * 100).toFixed(2)}%`
  const end = (Math.hypot(Math.max(x, w - x), Math.max(y, h - y)) / (Math.hypot(w, h) / Math.SQRT2) * 100).toFixed(2)
  swap?.skipTransition()
  root.classList.add('theme-swap')
  const transition = document.startViewTransition(() => apply(next))
  swap = transition
  transition.ready.then(() => root.animate(
    {clipPath: [`circle(0% at ${at})`, `circle(${end}% at ${at})`]},
    {duration: 620, easing: 'cubic-bezier(0.22, 1, 0.36, 1)', pseudoElement: '::view-transition-new(root)'}
  )).catch(() => {})
  transition.finished.finally(() => {if (swap === transition) {swap = null; root.classList.remove('theme-swap')}})
}
