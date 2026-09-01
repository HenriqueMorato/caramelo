import { Controller } from "@hotwired/stimulus"
import { Chart, CategoryScale, Filler, Legend, LinearScale, LineController, LineElement, PointElement, Tooltip } from "chart.js"

Chart.register(CategoryScale, Filler, Legend, LinearScale, LineController, LineElement, PointElement, Tooltip)

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
        datasets: [
          {
            label: this.dataValue.portfolio_value_label,
            data: this.dataValue.values,
            borderColor: "#9b5d31",
            backgroundColor: "rgba(196, 129, 79, 0.14)",
            borderWidth: 2,
            pointRadius: 0,
            pointHoverRadius: 4,
            pointHitRadius: 16,
            fill: true,
            tension: 0.25
          },
          {
            label: this.dataValue.invested_value_label,
            data: this.dataValue.invested_values,
            borderColor: "#766b60",
            borderDash: [5, 4],
            borderWidth: 1.5,
            pointRadius: 0,
            pointHoverRadius: 3,
            pointHitRadius: 16,
            fill: false,
            tension: 0.25
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? false : undefined,
        interaction: { mode: "index", intersect: false, axis: "x" },
        plugins: {
          legend: {
            display: true,
            labels: { color: "#4c3d31", boxWidth: 18, boxHeight: 2, usePointStyle: true, padding: 16 }
          },
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
              label: (item) => {
                const formattedValue = item.datasetIndex === 1
                  ? this.dataValue.formatted_invested_values[item.dataIndex]
                  : this.dataValue.formatted_values[item.dataIndex]
                const valueLabel = item.datasetIndex === 1
                  ? this.dataValue.invested_value_label
                  : this.dataValue.portfolio_value_label
                const performance = item.datasetIndex === 0
                  ? this.dataValue.formatted_performances?.[item.dataIndex]
                  : null
                const performanceLabel = performance && `${this.dataValue.return_label}: ${performance}`
                return [`${valueLabel}: ${formattedValue}`, performanceLabel].filter(Boolean)
              },
              labelTextColor: (item) => {
                if (item.datasetIndex === 1) return "#766b60"

                const performance = this.dataValue.performance_ratios?.[item.dataIndex]
                if (performance === undefined || performance === null || performance === 0) return "#766b60"

                return performance < 0 ? "#e76f51" : "#56805d"
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
