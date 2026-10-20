import { Controller } from "@hotwired/stimulus"

// 「科目を追加」の行き先を決める。最後に触った行の下に足す。
// どの行にも触れていなければ、表のいちばん下に足す。
export default class extends Controller {
  static targets = ["rowId", "label"]

  // 表の行(tbody)に入ったとき・押したときに呼ばれる。
  select(event) {
    const row = event.target.closest("tbody[data-row-id]")
    if (!row) return

    this.rowIdTarget.value = row.dataset.rowId
    this.element.querySelectorAll("tbody.ring-inset").forEach((other) => other.classList.remove("ring-inset", "ring-2", "ring-blue-600"))
    row.classList.add("ring-inset", "ring-2", "ring-blue-600")
    const code = row.querySelector("input[data-lecture-code]")
    this.labelTarget.textContent = code?.value ? `${code.value} の下に` : "選んでいる行の下に"
  }
}
