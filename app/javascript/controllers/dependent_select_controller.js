import { Controller } from "@hotwired/stimulus"

// 親の選択(学部)に合わせて、子の選択肢(学科)を絞る。
// 子には全学科を <optgroup label="学部名"> で出しておき、選ばれた学部のものだけ残す。
export default class extends Controller {
  static targets = ["parent", "child"]

  connect() {
    this.filter()
  }

  filter() {
    const selected = this.parentTarget.selectedOptions[0]?.text
    let visible = 0

    for (const group of this.childTarget.querySelectorAll("optgroup")) {
      const matches = group.label === selected
      group.hidden = !matches
      group.disabled = !matches
      if (matches) visible += group.children.length
    }

    // 隠れた学部の学科が選ばれたままにならないようにする
    const chosen = this.childTarget.selectedOptions[0]
    if (!chosen || chosen.parentElement.hidden) this.childTarget.value = ""
    this.childTarget.disabled = visible === 0
  }
}
