import { Controller } from "@hotwired/stimulus"

// PDFの選択欄。ボタンで選ぶ・ドラッグ&ドロップのどちらでも選べ、選んだファイル名を表示する。
export default class extends Controller {
  static targets = ["input", "name", "zone"]

  choose() {
    this.inputTarget.click()
  }

  changed() {
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
    if (event.dataTransfer.files.length === 0) return
    this.inputTarget.files = event.dataTransfer.files
    this.changed()
  }
}
