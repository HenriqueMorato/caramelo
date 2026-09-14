import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

const CHANNEL_NAME = "caramelo.money-visibility"

export default class extends Controller {
  connect() {
    this.channel = new BroadcastChannel(CHANNEL_NAME)
    this.channel.addEventListener("message", this.visibilityChanged)
  }

  disconnect() {
    this.channel?.removeEventListener("message", this.visibilityChanged)
    this.channel?.close()
  }

  changed(event) {
    if (!event.detail.success) return

    Turbo.cache.clear()
    this.channel.postMessage("changed")
  }

  visibilityChanged = () => {
    Turbo.cache.clear()
    window.location.reload()
  }
}
