import { Controller } from "@hotwired/stimulus"

// 「確認済み」のチェックボックスを扱う。
// - チェックを入れた(外した)時点で、そのまま更新を送る
// - 見出しのチェックで、全行を入れ外しする
export default class extends Controller {
  static targets = ["box", "all"]

  toggle() {
    this.syncAll()
    this.update()
  }

  toggleAll() {
    this.boxTargets.forEach((box) => { box.checked = this.allTarget.checked })
    this.syncAll()
    this.update()
  }

  // ボタンを押さずに送る。operationを付けないので、ふつうの更新として扱われる。
  // 入力中の値も同じフォームなので、一緒に保存される。
  update() {
    this.element.requestSubmit()
  }

  syncAll() {
    if (!this.hasAllTarget) return

    const checked = this.boxTargets.filter((box) => box.checked).length
    this.allTarget.checked = checked > 0 && checked === this.boxTargets.length
    this.allTarget.indeterminate = checked > 0 && checked < this.boxTargets.length
  }
}
