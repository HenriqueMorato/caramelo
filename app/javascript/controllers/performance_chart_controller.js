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
    context.strokeStyle = themeColor("--caramelo-chart-guide")
    context.moveTo(x, top)
    context.lineTo(x, bottom)
    context.stroke()
    context.restore()
  }
}

const benchmarkColorProperties = {
  IBOV: "--caramelo-benchmark-ibov",
  SP500: "--caramelo-benchmark-sp500",
  CDI: "--caramelo-benchmark-cdi"
}

const themeColor = (property) => getComputedStyle(document.documentElement).getPropertyValue(property).trim()

export default class extends Controller {
  static targets = ["canvas", "tab"]
  static values = { data: Object, defaultMode: String, returnOnly: Boolean }

  connect() {
    this.mode = this.requestedMode()
    this.colors = this.themeColors()
    this.portfolioReturnDataset = {
      label: this.dataValue.portfolio_return_label,
      data: this.dataValue.performance_ratios.map((value) => value === null ? null : Number(value) * 100),
      borderColor: this.colors.portfolio,
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
    this.gainOnCostReturnDataset = this.dataValue.gain_on_cost_performance_ratios && {
      label: this.dataValue.gain_on_cost_return_label,
      data: this.dataValue.gain_on_cost_performance_ratios.map((value) => value === null ? null : Number(value) * 100),
      borderColor: this.colors.comparison,
      borderWidth: 2.25,
      pointRadius: 0,
      pointHoverRadius: 4,
      pointHitRadius: 16,
      fill: false,
      tension: 0.25,
      hidden: true,
      role: "gain-on-cost-return",
      yAxisID: "return"
    }
    this.benchmarkDatasets = (this.dataValue.benchmarks || []).map((benchmark, index) => ({
      label: benchmark.label,
      data: benchmark.values,
      borderColor: this.benchmarkColor(benchmark.identifier, index),
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
    const returnDatasets = [
      this.portfolioReturnDataset,
      this.gainOnCostReturnDataset,
      ...this.benchmarkDatasets
    ].filter(Boolean)
    const returnValues = returnDatasets
      .flatMap((dataset) => dataset.data)
      .filter((value) => value !== null && value !== undefined)
    const returnMinimum = Math.min(0, ...returnValues)
    const returnMaximum = Math.max(0, ...returnValues)
    const returnPadding = Math.max((returnMaximum - returnMinimum) * 0.1, 1)
    const valueDatasets = [
      {
        label: this.dataValue.portfolio_value_label,
        data: this.dataValue.values,
        borderColor: this.colors.portfolio,
        backgroundColor: this.colors.portfolioFill,
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
        borderColor: this.colors.invested,
        borderDash: [5, 4],
        borderWidth: 2.25,
        pointRadius: 0,
        pointHoverRadius: 3,
        pointHitRadius: 16,
        fill: false,
        tension: 0.25,
        hidden: this.mode === "performance",
        role: "invested-value"
      }
    ]
    const datasets = this.returnOnlyValue
      ? returnDatasets
      : [...valueDatasets, ...returnDatasets]

    this.chart = new Chart(this.canvasTarget, {
      type: "line",
      plugins: [hoverGuidePlugin],
      data: {
        labels: this.dataValue.labels,
        datasets
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
              color: this.colors.text,
              boxWidth: 20,
              boxHeight: 3,
              usePointStyle: true,
              padding: 16,
              generateLabels: (chart) => Chart.defaults.plugins.legend.labels.generateLabels(chart)
                .filter((item) => this.datasetVisibleInMode(chart.data.datasets[item.datasetIndex]))
                .map((item) => ({
                  ...item,
                  fontColor: chart.data.datasets[item.datasetIndex]?.borderColor || this.colors.text
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
            backgroundColor: this.colors.tooltip,
            borderColor: this.colors.border,
            borderWidth: 1,
            cornerRadius: 8,
            padding: 10,
            titleColor: this.colors.text,
            titleFont: { family: "inherit", size: 12, weight: "600" },
            bodyColor: this.colors.text,
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

                if (["portfolio-return", "gain-on-cost-return"].includes(dataset.role)) {
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
                if (dataset.role === "invested-value") return this.colors.invested
                if (["benchmark", "portfolio-return", "gain-on-cost-return"].includes(dataset.role)) {
                  return dataset.borderColor
                }

                const performance = this.dataValue.performance_ratios?.[item.dataIndex]
                if (performance === undefined || performance === null || performance === 0) return this.colors.invested

                return performance < 0 ? this.colors.negative : this.colors.positive
              }
            }
          }
        },
        scales: {
          x: { grid: { display: false }, ticks: { maxTicksLimit: 7, color: this.colors.invested } },
          y: {
            display: this.mode === "value",
            beginAtZero: true,
            grid: { color: this.colors.grid },
            ticks: {
              color: this.colors.invested,
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
            grid: { color: this.colors.grid },
            ticks: {
              color: this.colors.invested,
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

  refreshTheme() {
    if (!this.chart) return

    this.colors = this.themeColors()
    this.chart.data.datasets.forEach((dataset, index) => {
      if (dataset.role === "portfolio-value") dataset.backgroundColor = this.colors.portfolioFill
      dataset.borderColor = this.datasetColor(dataset, index)
    })
    this.chart.options.plugins.legend.labels.color = this.colors.text
    Object.assign(this.chart.options.plugins.tooltip, {
      backgroundColor: this.colors.tooltip,
      borderColor: this.colors.border,
      titleColor: this.colors.text,
      bodyColor: this.colors.text
    })
    this.chart.options.scales.x.ticks.color = this.colors.invested
    const verticalScales = [this.chart.options.scales.y, this.chart.options.scales.return]
    verticalScales.forEach((scale) => {
      scale.grid.color = this.colors.grid
      scale.ticks.color = this.colors.invested
    })
    this.chart.update("none")
  }

  refreshVisibility() {
    if (!this.chart || this.element.closest("[hidden]")) return

    this.chart.resize()
    this.setMode(this.requestedMode(), false)
  }

  setMode(mode, updateUrl = true) {
    if (!this.chart || !["value", "performance"].includes(mode)) return

    this.mode = mode
    this.chart.data.datasets.forEach((dataset, index) => {
      this.chart.setDatasetVisibility(index, this.datasetDefaultVisibleInMode(dataset))
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

  datasetDefaultVisibleInMode(dataset) {
    return dataset.role !== "gain-on-cost-return" && this.datasetVisibleInMode(dataset)
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
    if (this.hasDefaultModeValue) return this.defaultModeValue

    return new URL(window.location.href).searchParams.get("chart") === "performance" ? "performance" : "value"
  }

  datasetColor(dataset, index) {
    if (dataset.role === "benchmark") return this.benchmarkColor(dataset.benchmark.identifier, index)
    if (dataset.role === "invested-value") return this.colors.invested
    if (dataset.role === "gain-on-cost-return") return this.colors.comparison

    return this.colors.portfolio
  }

  benchmarkColor(identifier, index) {
    const properties = Object.values(benchmarkColorProperties)
    const property = benchmarkColorProperties[identifier] || properties[index % properties.length]
    return themeColor(property)
  }

  themeColors() {
    return {
      portfolio: themeColor("--caramelo-chart-line"),
      portfolioFill: themeColor("--caramelo-chart-fill"),
      comparison: themeColor("--caramelo-benchmark-ibov"),
      invested: themeColor("--caramelo-chart-invested"),
      text: themeColor("--caramelo-ink"),
      tooltip: themeColor("--caramelo-raised"),
      border: themeColor("--caramelo-chart-border"),
      grid: themeColor("--caramelo-chart-grid"),
      positive: themeColor("--caramelo-positive"),
      negative: themeColor("--caramelo-negative")
    }
  }
}
