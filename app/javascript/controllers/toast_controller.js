import { Controller } from "@hotwired/stimulus"

// 画面上部に固定表示するメッセージ。成功は数秒で消え、エラーは閉じるまで残す。
export default class extends Controller {
  static values = { autoDismiss: Number }

  connect() {
    if (this.autoDismissValue > 0) {
      this.timer = setTimeout(() => this.close(), this.autoDismissValue)
    }
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  close() {
    this.element.remove()
  }
}
