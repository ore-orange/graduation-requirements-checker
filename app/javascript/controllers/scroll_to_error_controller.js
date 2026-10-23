import { Controller } from "@hotwired/stimulus"

// エラーのある行(data-error-row)があれば、最初の行が画面の中央に来るようスクロールする。
export default class extends Controller {
  connect() {
    this.scroll = this.scroll.bind(this)
    document.addEventListener("turbo:morph", this.scroll)
    this.scroll()
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.scroll)
  }

  scroll() {
    const row = this.element.querySelector("[data-error-row]")
    if (row) row.scrollIntoView({ block: "center", behavior: "smooth" })
  }
}
