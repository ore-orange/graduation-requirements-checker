import { Controller } from "@hotwired/stimulus"

// PDFの選択欄。ボタンで選ぶ・ドラッグ&ドロップのどちらでも選べ、選んだファイル名を表示する。
export default class extends Controller {
  static targets = ["input", "name", "zone", "error"]

  choose() {
    this.inputTarget.click()
  }

  changed() {
    this.errorTarget.hidden = true
    const file = this.inputTarget.files[0]
    this.nameTarget.textContent = file ? file.name : "ファイルが選ばれていません"
  }

  dragOver(event) {
    event.preventDefault()
    this.zoneTarget.classList.add("border-slate-900", "bg-slate-50")
  }

  dragLeave() {
    this.zoneTarget.classList.remove("border-slate-900", "bg-slate-50")
  }

  drop(event) {
    event.preventDefault()
    this.dragLeave()
    const files = Array.from(event.dataTransfer.files)
    if (files.length === 0) return
    // ファイル選択は accept で絞られるが、ドロップは絞られない。サーバーが断るのと同じ文言を、送る前に出す。
    // 選び済みのファイルはそのまま残す。
    if (!files.every((file) => this.isPdf(file))) {
      this.errorTarget.hidden = false
      return
    }
    this.inputTarget.files = event.dataTransfer.files
    this.changed()
  }

  // accept="application/pdf" と同じく、種類で見る。種類が空で渡るOS・ブラウザがあるので、拡張子も見る。
  isPdf(file) {
    return file.type === "application/pdf" || (file.type === "" && /\.pdf$/i.test(file.name))
  }
}
