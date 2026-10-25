import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["banner"]
  static values = { acknowledgeUrl: String, achievedAt: String }

  connect() {
    this.startFireworks()
    this.acknowledge()
  }

  disconnect() {
    this.stopFireworks()
  }

  dismiss(event) {
    event?.preventDefault()
    this.bannerTarget.hidden = true
    this.bannerTarget.inert = true
    this.stopFireworks()
    this.acknowledge()
  }

  startFireworks() {
    this.canvas = this.element.querySelector(".goal-fireworks")
    if (!this.canvas || this.reducedMotion()) return

    this.canvasContext = this.canvas.getContext("2d")
    if (!this.canvasContext) return

    this.resizeCanvas()
    this.bursts = this.createBursts()
    this.startedAt = this.now()
    this.animate = this.animate.bind(this)
    this.frame = window.requestAnimationFrame(this.animate)

    if (window.ResizeObserver) {
      this.resizeObserver = new window.ResizeObserver(() => this.resizeCanvas())
      this.resizeObserver.observe(this.canvas)
    }
  }

  stopFireworks() {
    if (this.frame) window.cancelAnimationFrame(this.frame)
    this.resizeObserver?.disconnect()
    this.frame = null
    this.resizeObserver = null
    this.canvasContext?.clearRect(0, 0, this.width || 0, this.height || 0)
  }

  reducedMotion() {
    return window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches
  }

  now() {
    return window.performance?.now?.() || Date.now()
  }

  resizeCanvas() {
    const rectangle = this.canvas.getBoundingClientRect()
    const width = Math.max(1, rectangle.width)
    const height = Math.max(1, rectangle.height)
    const pixelRatio = Math.min(window.devicePixelRatio || 1, 2)

    this.width = width
    this.height = height
    this.shortSide = Math.min(width, height)
    this.canvas.width = Math.round(width * pixelRatio)
    this.canvas.height = Math.round(height * pixelRatio)
    this.canvasContext?.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0)
  }

  createBursts() {
    const styles = getComputedStyle(this.element)
    const colors = [
      styles.getPropertyValue("--caramelo-caramel").trim(),
      styles.getPropertyValue("--caramelo-positive").trim(),
      styles.getPropertyValue("--caramelo-caramel-strong").trim()
    ].filter(Boolean)
    const positions = [
      { x: 0.2, y: 0.28 },
      { x: 0.5, y: 0.08 },
      { x: 0.8, y: 0.28 }
    ]

    return positions.map((position, burstIndex) => ({
      ...position,
      color: colors[burstIndex % colors.length] || "#c97a45",
      delay: burstIndex * 140,
      particles: Array.from({ length: 30 }, (_, particleIndex) => ({
        angle: (Math.PI * 2 * particleIndex) / 30 + (Math.random() - 0.5) * 0.16,
        distance: 0.3 + Math.random() * 0.17,
        length: 0.02 + Math.random() * 0.014,
        alpha: 0.72 + Math.random() * 0.28
      }))
    }))
  }

  animate(timestamp) {
    this.canvasContext.clearRect(0, 0, this.width, this.height)
    let active = false

    this.bursts.forEach((burst) => {
      const elapsed = timestamp - this.startedAt - burst.delay
      if (elapsed < 0) {
        active = true
        return
      }

      const progress = Math.min(elapsed / 920, 1)
      if (progress >= 1) return

      active = true
      this.drawBurst(burst, progress)
    })

    if (active) {
      this.frame = window.requestAnimationFrame(this.animate)
    } else {
      this.canvasContext.clearRect(0, 0, this.width, this.height)
      this.frame = null
    }
  }

  drawBurst(burst, progress) {
    const eased = 1 - ((1 - progress) ** 3)
    const fade = progress < 0.12 ? progress / 0.12 : (1 - progress) ** 0.8
    const centerX = burst.x * this.width
    const centerY = burst.y * this.height

    this.canvasContext.save()
    this.canvasContext.translate(centerX, centerY)
    this.canvasContext.globalCompositeOperation = "lighter"
    this.canvasContext.lineCap = "round"

    burst.particles.forEach((particle) => {
      const radius = this.shortSide * particle.distance * eased
      const trail = this.shortSide * particle.length * (1 - progress * 0.45)
      const gravity = this.shortSide * 0.035 * progress ** 2
      const x = Math.cos(particle.angle) * radius
      const y = Math.sin(particle.angle) * radius + gravity
      const startX = Math.cos(particle.angle) * Math.max(0, radius - trail)
      const startY = Math.sin(particle.angle) * Math.max(0, radius - trail) + gravity * 0.75

      this.canvasContext.strokeStyle = burst.color
      this.canvasContext.globalAlpha = fade * particle.alpha
      this.canvasContext.lineWidth = Math.max(0.8, this.shortSide * 0.009)
      this.canvasContext.beginPath()
      this.canvasContext.moveTo(startX, startY)
      this.canvasContext.lineTo(x, y)
      this.canvasContext.stroke()

      this.canvasContext.fillStyle = burst.color
      this.canvasContext.globalAlpha = fade * particle.alpha * 0.9
      this.canvasContext.beginPath()
      this.canvasContext.arc(x, y, Math.max(0.8, this.shortSide * 0.0095), 0, Math.PI * 2)
      this.canvasContext.fill()
    })

    if (progress < 0.3) {
      this.canvasContext.fillStyle = burst.color
      this.canvasContext.globalAlpha = fade * (1 - progress / 0.3) * 0.8
      this.canvasContext.beginPath()
      this.canvasContext.arc(0, 0, Math.max(1.5, this.shortSide * 0.016), 0, Math.PI * 2)
      this.canvasContext.fill()
    }

    this.canvasContext.restore()
  }

  async acknowledge() {
    const token = document.querySelector("meta[name='csrf-token']")?.content
    if (!token || !this.acknowledgeUrlValue) return

    try {
      await fetch(this.acknowledgeUrlValue, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "X-CSRF-Token": token,
          Accept: "application/json",
          "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"
        },
        body: new URLSearchParams({ achieved_at: this.achievedAtValue })
      })
    } catch (_) {
      // Keep the celebration available when a transient request fails.
    }
  }
}
