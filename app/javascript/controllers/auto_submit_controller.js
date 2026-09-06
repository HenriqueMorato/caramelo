import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  submit(event) {
    const form = event.currentTarget.form

    if (form.method.toLowerCase() !== "get") {
      form.requestSubmit()
      return
    }

    const url = new URL(form.action)
    const params = new URLSearchParams()

    new FormData(form).forEach((value, key) => {
      if (value.toString().length > 0) params.append(key, value)
    })

    url.search = params.toString()
    Turbo.visit(url.toString())
  }
}
