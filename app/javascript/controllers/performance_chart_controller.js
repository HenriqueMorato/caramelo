import { Controller } from "@hotwired/stimulus"
import { Chart, CategoryScale, Filler, LinearScale, LineController, LineElement, PointElement, Tooltip } from "chart.js"

Chart.register(CategoryScale, Filler, LinearScale, LineController, LineElement, PointElement, Tooltip)

const hoverGuidePlugin = {
  id: "hoverGuide",

  afterDraw(chart) {
    const activeElements = chart.tooltip?.getActiveElements?.()
    if (!activeElements?.length) return

    const x = activeElements[0].element.x
    const { bottom, top } = chart.chartArea
    const context = chart.ctx

    context.save()
    context.beginPath()
    context.setLineDash([3, 4])
    context.lineWidth = 1
    context.strokeStyle = "rgba(155, 93, 49, 0.42)"
    context.moveTo(x, top)
    context.lineTo(x, bottom)
    context.stroke()
    context.restore()
  }
}

export default class extends Controller {
  static targets = ["canvas"]
  static values = { data: Object }

  connect() {
    this.chart = new Chart(this.canvasTarget, {
      type: "line",
      plugins: [hoverGuidePlugin],
      data: {
        labels: this.dataValue.labels,
        datasets: [ {
          data: this.dataValue.values,
          borderColor: "#9b5d31",
          backgroundColor: "rgba(196, 129, 79, 0.14)",
          borderWidth: 2,
          pointRadius: 0,
          pointHoverRadius: 4,
          pointHitRadius: 16,
          fill: true,
          tension: 0.25
        } ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false, axis: "x" },
        plugins: {
          legend: { display: false },
          tooltip: {
            mode: "index",
            intersect: false,
            displayColors: false,
            backgroundColor: "#fbf8f2",
            borderColor: "rgba(76, 61, 49, 0.16)",
            borderWidth: 1,
            cornerRadius: 8,
            padding: 10,
            titleColor: "#4c3d31",
            titleFont: { family: "inherit", size: 12, weight: "600" },
            bodyColor: "#4c3d31",
            bodyFont: { family: "inherit", size: 12, weight: "600" },
            bodySpacing: 4,
            callbacks: {
              title: (items) => this.dataValue.labels[items[0].dataIndex],
              label: (item) => [
                this.dataValue.formatted_values[item.dataIndex],
                this.dataValue.formatted_performances?.[item.dataIndex]
              ].filter(Boolean),
              labelTextColor: (item) => {
                const performance = this.dataValue.formatted_performances?.[item.dataIndex]
                return performance?.startsWith("↓") ? "#e76f51" : "#56805d"
              }
            }
          }
        },
        scales: {
          x: { grid: { display: false }, ticks: { maxTicksLimit: 7, color: "#766b60" } },
          y: {
            beginAtZero: true,
            grid: { color: "rgba(76, 61, 49, 0.12)" },
            ticks: {
              color: "#766b60",
              callback: (value) => new Intl.NumberFormat(undefined, {
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
