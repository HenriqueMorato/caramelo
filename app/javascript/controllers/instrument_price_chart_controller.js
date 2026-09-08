import { Controller } from "@hotwired/stimulus"
import { Chart, CategoryScale, Filler, LinearScale, LineController, LineElement, PointElement, Tooltip } from "chart.js"

Chart.register(CategoryScale, Filler, LinearScale, LineController, LineElement, PointElement, Tooltip)

const themeColor = (property) => getComputedStyle(document.documentElement).getPropertyValue(property).trim()

export default class extends Controller {
  static targets = ["canvas"]
  static values = { data: Object }

  connect() {
    this.chart = new Chart(this.canvasTarget, {
      type: "line",
      data: {
        labels: this.dataValue.labels,
        datasets: [{
          label: this.dataValue.label,
          data: this.dataValue.values,
          borderColor: themeColor("--caramelo-chart-line"),
          backgroundColor: themeColor("--caramelo-chart-fill"),
          borderWidth: 2.5,
          pointRadius: 0,
          pointHoverRadius: 4,
          pointHitRadius: 16,
          fill: true,
          tension: 0.25
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? false : undefined,
        interaction: { mode: "index", intersect: false, axis: "x" },
        plugins: {
          legend: { display: false },
          tooltip: {
            displayColors: false,
            backgroundColor: themeColor("--caramelo-raised"),
            borderColor: themeColor("--caramelo-chart-border"),
            borderWidth: 1,
            cornerRadius: 8,
            padding: 10,
            titleColor: themeColor("--caramelo-ink"),
            bodyColor: themeColor("--caramelo-ink"),
            callbacks: {
              label: (item) => `${this.dataValue.label}: ${this.dataValue.formatted_values[item.dataIndex]}`
            }
          }
        },
        scales: {
          x: {
            grid: { display: false },
            ticks: { maxTicksLimit: 6, color: themeColor("--caramelo-muted") }
          },
          y: {
            grid: { color: themeColor("--caramelo-chart-grid") },
            ticks: {
              color: themeColor("--caramelo-muted"),
              callback: (value) => new Intl.NumberFormat(this.dataValue.locale, {
                style: "currency", currency: this.dataValue.currency, maximumFractionDigits: 2
              }).format(value)
            }
          }
        }
      }
    })
  }

  disconnect() {
    this.chart?.destroy()
  }
}
