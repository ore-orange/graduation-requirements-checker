import { Controller } from "@hotwired/stimulus"

// 全学期の一覧で、押したマスの区分と学期に科目を追加する小窓を開く。
// 小窓は区分ごとに1つで、学期は開くときに差し込む。
export default class extends Controller {
  static targets = ["dialog"]

  open({ params: { row, term, termLabel } }) {
    const dialog = this.dialogTargets.find((target) => target.dataset.row === row)

    dialog.querySelector("[data-term-field]").value = term
    dialog.querySelector("[data-term-name]").textContent = termLabel
    dialog.showModal()
  }

  close({ target }) {
    target.closest("dialog").close()
  }

  closeOnBackdrop({ target }) {
    if (target.tagName === "DIALOG") target.close()
  }
}
