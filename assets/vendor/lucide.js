// Lucide geometry used by Gloss, bundled like the generated Heroicons plugin.
const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(({matchComponents, theme}) => {
  const directory = path.join(__dirname, "lucide")
  const values = Object.fromEntries(fs.readdirSync(directory)
    .filter(file => file.endsWith(".svg"))
    .map(file => [path.basename(file, ".svg"), file]))
  const icon = (file, stroke) => {
    const svg = fs.readFileSync(path.join(directory, file), "utf8").trim().replace('stroke-width="2"', `stroke-width="${stroke}"`)
    const mask = `url('data:image/svg+xml;utf8,${encodeURIComponent(svg)}')`
    return {
      "-webkit-mask": mask,
      mask,
      "mask-repeat": "no-repeat",
      "mask-size": "contain",
      "background-color": "currentColor",
      "vertical-align": "middle",
      display: "inline-block",
      "flex-shrink": "0",
      width: theme("spacing.6"),
      height: theme("spacing.6"),
    }
  }
  matchComponents({lucide: file => icon(file, 2), "lucide-thin": file => icon(file, 1.5)}, {values})
})
