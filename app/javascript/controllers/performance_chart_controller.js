import { Controller } from "@hotwired/stimulus"
import {
  Chart,
  CategoryScale,
  Filler,
  Legend,
  LinearScale,
  LineController,
  LineElement,
  PointElement,
  Tooltip
} from "chart.js"

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

const benchmarkColors = { IBOV: "#3f5f86", SP500: "#7b3f78", CDI: "#b27a1f" }
const fallbackBenchmarkColors = Object.values(benchmarkColors)

export default class extends Controller {
  static targets = ["canvas", "tab"]
  static values = { data: Object }

  connect() {
    this.mode = this.requestedMode()
    this.portfolioReturnDataset = {
      label: this.dataValue.portfolio_return_label,
      data: this.dataValue.performance_ratios.map((value) => value === null ? null : Number(value) * 100),
      borderColor: "#9b5d31",
      borderWidth: 3,
      pointRadius: 0,
      pointHoverRadius: 4,
      pointHitRadius: 16,
      fill: false,
      tension: 0.25,
      hidden: this.mode !== "performance",
      role: "portfolio-return",
      yAxisID: "return"
    }
    this.benchmarkDatasets = (this.dataValue.benchmarks || []).map((benchmark, index) => ({
      label: benchmark.label,
      data: benchmark.values,
      borderColor: benchmarkColors[benchmark.identifier] ||
        fallbackBenchmarkColors[index % fallbackBenchmarkColors.length],
      borderWidth: 1.75,
      pointRadius: 0,
      pointHitRadius: 12,
      fill: false,
      tension: 0.25,
      hidden: this.mode !== "performance",
      role: "benchmark",
      benchmark,
      yAxisID: "return"
    }))
    const returnValues = [this.portfolioReturnDataset, ...this.benchmarkDatasets]
      .flatMap((dataset) => dataset.data)
      .filter((value) => value !== null && value !== undefined)
    const returnMinimum = Math.min(0, ...returnValues)
    const returnMaximum = Math.max(0, ...returnValues)
    const returnPadding = Math.max((returnMaximum - returnMinimum) * 0.1, 1)
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
            borderWidth: 3,
            pointRadius: 0,
            pointHoverRadius: 4,
            pointHitRadius: 16,
            fill: true,
            tension: 0.25,
            hidden: this.mode === "performance",
            role: "portfolio-value"
          },
          {
            label: this.dataValue.invested_value_label,
            data: this.dataValue.invested_values,
            borderColor: "#766b60",
            borderDash: [5, 4],
            borderWidth: 2.25,
            pointRadius: 0,
            pointHoverRadius: 3,
            pointHitRadius: 16,
            fill: false,
            tension: 0.25,
            hidden: this.mode === "performance",
            role: "invested-value"
          },
          this.portfolioReturnDataset,
          ...this.benchmarkDatasets
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
            labels: {
              color: "#4c3d31",
              boxWidth: 20,
              boxHeight: 3,
              usePointStyle: true,
              padding: 16,
              generateLabels: (chart) => Chart.defaults.plugins.legend.labels.generateLabels(chart)
                .filter((item) => this.datasetVisibleInMode(chart.data.datasets[item.datasetIndex]))
                .map((item) => ({
                  ...item,
                  fontColor: chart.data.datasets[item.datasetIndex]?.borderColor || "#4c3d31"
                }))
            },
            onClick: (event, legendItem, legend) => {
              const chart = legend.chart
              const datasetIndex = legendItem.datasetIndex
              chart.setDatasetVisibility(datasetIndex, !chart.isDatasetVisible(datasetIndex))
              chart.update()
            }
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
                const dataset = item.dataset
                if (dataset.role === "benchmark") {
                  const benchmark = dataset.benchmark
                  const value = dataset.data[item.dataIndex]
                  return value === null || value === undefined
                    ? `${benchmark.label}: Not available`
                    : `${benchmark.label}: ${value > 0 ? "+" : ""}${value.toFixed(2)}%`
                }

                if (dataset.role === "portfolio-return") {
                  const value = dataset.data[item.dataIndex]
                  return value === null || value === undefined
                    ? `${dataset.label}: Not available`
                    : `${dataset.label}: ${value > 0 ? "+" : ""}${value.toFixed(2)}%`
                }

                const formattedValue = dataset.role === "invested-value"
                  ? this.dataValue.formatted_invested_values[item.dataIndex]
                  : this.dataValue.formatted_values[item.dataIndex]
                const valueLabel = dataset.role === "invested-value"
                  ? this.dataValue.invested_value_label
                  : this.dataValue.portfolio_value_label
                const performance = dataset.role === "portfolio-value"
                  ? this.dataValue.formatted_performances?.[item.dataIndex]
                  : null
                const performanceLabel = performance && `${this.dataValue.return_label}: ${performance}`
                return [`${valueLabel}: ${formattedValue}`, performanceLabel].filter(Boolean)
              },
              labelTextColor: (item) => {
                const dataset = item.dataset
                if (dataset.role === "invested-value") return "#766b60"
                if (["benchmark", "portfolio-return"].includes(dataset.role)) return dataset.borderColor

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
            display: this.mode === "value",
            beginAtZero: true,
            grid: { color: "rgba(76, 61, 49, 0.12)" },
            ticks: {
              color: "#766b60",
              callback: (value) => new Intl.NumberFormat(this.dataValue.locale, {
                style: "currency", currency: this.dataValue.currency, maximumFractionDigits: 2
              }).format(value)
            }
          },
          return: {
            display: this.mode === "performance",
            position: "left",
            min: returnMinimum - returnPadding,
            max: returnMaximum + returnPadding,
            grid: { color: "rgba(76, 61, 49, 0.12)" },
            ticks: {
              color: "#766b60",
              callback: (value) => `${value > 0 ? "+" : ""}${value.toFixed(1)}%`
            }
          }
        }
      }
    })
    this.updateTabs()
  }

  disconnect() {
    this.chart?.destroy()
  }

  selectMode(event) {
    this.setMode(event.params.mode)
  }

  selectModeWithKeyboard(event) {
    if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return

    event.preventDefault()
    const mode = this.mode === "value" ? "performance" : "value"
    this.setMode(mode)
    this.tabTargets.find((tab) => tab.dataset.performanceChartModeParam === mode)?.focus()
  }

  restoreMode() {
    this.setMode(this.requestedMode(), false)
  }

  setMode(mode, updateUrl = true) {
    if (!this.chart || !["value", "performance"].includes(mode)) return

    this.mode = mode
    this.chart.data.datasets.forEach((dataset, index) => {
      this.chart.setDatasetVisibility(index, this.datasetVisibleInMode(dataset))
    })
    this.chart.options.scales.y.display = mode === "value"
    this.chart.options.scales.return.display = mode === "performance"
    this.updateTabs()
    this.chart.update()
    if (updateUrl) this.updateUrl()
  }

  datasetVisibleInMode(dataset) {
    const valueDataset = ["portfolio-value", "invested-value"].includes(dataset.role)
    return this.mode === "value" ? valueDataset : !valueDataset
  }

  updateTabs() {
    this.tabTargets.forEach((tab) => {
      const active = tab.dataset.performanceChartModeParam === this.mode
      tab.dataset.active = active.toString()
      tab.setAttribute("aria-selected", active.toString())
      tab.tabIndex = active ? 0 : -1
    })
  }

  updateUrl() {
    const url = new URL(window.location.href)
    if (this.mode === "value") {
      url.searchParams.delete("chart")
    } else {
      url.searchParams.set("chart", this.mode)
    }
    window.history.pushState({}, "", url)
  }

  requestedMode() {
    return new URL(window.location.href).searchParams.get("chart") === "performance" ? "performance" : "value"
  }
}
