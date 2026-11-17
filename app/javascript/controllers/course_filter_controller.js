import { Controller } from "@hotwired/stimulus"

// 計画表の追加ボックスで、便覧の科目を科目名・科目番号で絞り込む。
// 一覧にある科目からしか選べない。一覧にない値を打ち込む欄ではない。
export default class extends Controller {
  static targets = ["query", "select", "empty", "submit"]

  // option を隠すだけでは Safari で消えないので、元の一覧を取っておいて入れ替える。
  connect() {
    this.options = Array.from(this.selectTarget.options)
  }

  filter() {
    const query = this.normalize(this.queryTarget.value)
    const matched = this.options.filter((option) => this.normalize(option.dataset.search).includes(query))

    this.selectTarget.replaceChildren(...matched)
    if (matched.length > 0) this.selectTarget.selectedIndex = 0
    this.emptyTarget.hidden = matched.length > 0
    this.submitTarget.disabled = matched.length === 0
  }

  // 全角・半角と大文字・小文字の違いは区別しない（「３２６」でも「326」でも当たる）。
  normalize(text) {
    return (text || "").normalize("NFKC").toLowerCase().trim()
  }
}
