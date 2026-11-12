import { Controller } from "@hotwired/stimulus"

// 対象の区分のチップに、選んだ区分をその場で足す(設計書 項目2)。
//
// 画面に出すのは、いま選んである区分のチップと、足す区分を選ぶ選択肢1つだけ。
// 便覧の区分を23個のチェックとして並べると、行と決まりの数だけ繰り返して1画面が重くなる。
//
// JavaScript が動かなくても足せる。選択肢を選んで保存すれば、保存の側(RequirementsEdit)が
// その区分をチップの欄に足す。ここがするのは、保存を待たずに同じ結果を見せることだけ。
export default class extends Controller {
  static targets = ["chips", "select"]

  add() {
    const option = this.selectTarget.selectedOptions[0]
    if (!option?.value) return

    this.chipsTarget.appendChild(this.chip(option.value, option.text))
    option.remove()
    // 足した区分はチップが送るので、選択肢は空に戻す(同じ値を2か所から送らない)
    this.selectTarget.value = ""
    if (this.selectTarget.options.length <= 1) this.selectTarget.hidden = true
  }

  // 保存してから描き直したときと同じ形のチップ(チェックが入っていて、ラベルの × で外せる)。
  chip(value, label) {
    const wrapper = document.createElement("label")
    wrapper.className = "rv-chip"

    const box = document.createElement("input")
    box.type = "checkbox"
    box.name = this.selectTarget.dataset.name
    box.value = value
    box.checked = true
    box.className = "peer sr-only"

    const text = document.createElement("span")
    text.className = "rv-chip-text"
    text.textContent = `${label} ×`

    wrapper.append(box, text)
    return wrapper
  }
}
