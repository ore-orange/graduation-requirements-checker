import { Controller } from "@hotwired/stimulus"

// 読み取り中のページがある間、数秒おきに状態を問い合わせる。読み取りが終わったら画面を読み込み直して結果を出す。
export default class extends Controller {
  static values = { url: String, interval: { type: Number, default: 5000 } }

  connect() {
    this.timer = setInterval(() => this.check(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async check() {
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      if (!response.ok) return
      const state = await response.json()
      if (!state.reading) {
        clearInterval(this.timer)
        window.Turbo.visit(window.location.href, { action: "replace" })
      }
    } catch {
      // 通信が一時的に切れても、次の問い合わせで取り直す。
    }
  }
}
