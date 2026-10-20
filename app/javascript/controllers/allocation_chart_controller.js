import { Controller } from "@hotwired/stimulus"
import { ArcElement, Chart, Legend, PieController, Tooltip } from "chart.js"

Chart.register(ArcElement, Legend, PieController, Tooltip)

const assetTypeColors = {
  "type:stock": "--caramelo-asset-stock",
  "type:etf": "--caramelo-asset-etf",
  "type:fund": "--caramelo-asset-fund",
  "type:bond": "--caramelo-asset-bond",
  "type:crypto": "--caramelo-asset-crypto",
  "type:other": "--caramelo-asset-other"
}

// A stable 20-color series keeps position slices distinct without semantic benchmark colors.
const positionPalette = [
  "--caramelo-asset-stock",
  "--caramelo-asset-etf",
  "--caramelo-asset-fund",
  "--caramelo-asset-bond",
  "--caramelo-asset-crypto",
  "--caramelo-asset-other",
  "--caramelo-series-rose",
  "--caramelo-series-olive",
  "--caramelo-series-indigo",
  "--caramelo-series-cyan",
  "--caramelo-series-rust",
  "--caramelo-series-forest",
  "--caramelo-series-berry",
  "--caramelo-series-clay",
  "--caramelo-series-denim",
  "--caramelo-series-mustard",
  "--caramelo-series-mulberry",
  "--caramelo-series-sea-green",
  "--caramelo-series-violet",
  "--caramelo-series-slate"
]

const themeColor = (property) => getComputedStyle(document.documentElement).getPropertyValue(property).trim()

const stableIndex = (value) => Array.from(value).reduce((hash, character) => ((hash * 31) + character.codePointAt(0)) >>> 0, 0)

const colorFor = (key) => themeColor(assetTypeColors[key] || positionPalette[stableIndex(key) % positionPalette.length])
const minimumLabelAngle = 0.75

const fitLabel = (context, label, maxWidth) => {
  if (context.measureText(label).width <= maxWidth) return label

  let shortened = label
  while (shortened.length > 1 && context.measureText(`${shortened}…`).width > maxWidth) shortened = shortened.slice(0, -1)
  return `${shortened}…`
}

const chartLabelColor = () => themeColor("--caramelo-on-accent")

const allocationLabelsPlugin = {
  id: "allocationLabels",

  afterDatasetsDraw(chart) {
    const meta = chart.getDatasetMeta(0)
    if (!meta?.data?.length) return

    const { ctx } = chart
    const labels = chart.data.labels || []
    const dataset = chart.data.datasets[0]
    const fontFamily = getComputedStyle(document.body).fontFamily || "sans-serif"

    ctx.save()
    ctx.font = `600 11px ${fontFamily}`
    ctx.textBaseline = "middle"

    meta.data.forEach((arc, index) => {
      const value = Number(dataset.data[index])
      if (!Number.isFinite(value) || value <= 0) return

      const span = Math.abs(arc.endAngle - arc.startAngle)
      const angle = (arc.startAngle + arc.endAngle) / 2
      const percentage = `${value.toFixed(value < 10 ? 1 : 0)}%`
      const label = String(labels[index] || "")
      const inside = span >= minimumLabelAngle && arc.outerRadius >= 70

      // Narrow slices stay uncluttered; their ticker and percentage remain available on hover.
      if (!inside) return

      const radius = (arc.innerRadius + arc.outerRadius) / 2
      const x = arc.x + Math.cos(angle) * radius
      const y = arc.y + Math.sin(angle) * radius
      const shortLabel = fitLabel(ctx, label, arc.outerRadius * 0.9)
      const lines = shortLabel ? [ shortLabel, percentage ] : [ percentage ]
      const lineHeight = 14

      ctx.fillStyle = chartLabelColor()
      ctx.textAlign = "center"
      lines.forEach((line, lineIndex) => {
        ctx.fillText(line, x, y + (lineIndex - ((lines.length - 1) / 2)) * lineHeight, arc.outerRadius * 0.9)
      })
    })

    ctx.restore()
  }
}

export default class extends Controller {
  static targets = [ "canvas" ]
  static values = { data: Object }

  connect() {
    this.render()
  }

  disconnect() {
    this.chart?.destroy()
  }

  refreshTheme() {
    this.chart?.destroy()
    this.render()
  }

  render() {
    const values = this.dataValue.values.map((value) => Number(value) * 100)
    const colorKeys = this.dataValue.color_keys || this.dataValue.labels.map((_, index) => `position:${index}`)
    const borderColor = themeColor("--caramelo-surface")
    Chart.getChart(this.canvasTarget)?.destroy()

    this.chart = new Chart(this.canvasTarget, {
      type: "pie",
      plugins: [allocationLabelsPlugin],
      data: {
        labels: this.dataValue.labels,
        datasets: [ {
          data: values,
          backgroundColor: colorKeys.map(colorFor),
          borderColor,
          borderWidth: 2,
          hoverOffset: 5
        } ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? false : undefined,
        plugins: {
          legend: {
            display: false
          },
          tooltip: {
            backgroundColor: themeColor("--caramelo-hero"),
            borderColor: themeColor("--caramelo-chart-border"),
            borderWidth: 1,
            cornerRadius: 8,
            padding: 10,
            titleColor: themeColor("--caramelo-hero-text"),
            bodyColor: themeColor("--caramelo-hero-text"),
            callbacks: {
              label: (context) => `${context.label}: ${Number(context.raw).toFixed(2)}%`
            }
          }
        }
      }
    })
  }
}
