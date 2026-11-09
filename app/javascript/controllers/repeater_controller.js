import { Controller } from "@hotwired/stimulus"

// 繰り返しの行(経路・条件など)を、画面で足したり消したりする。
//
// 足す行の中身は <template data-repeater-target="template"> に書いておき、行が並ぶ入れ物に
// data-repeater-target="list" を付ける。足すボタンは data-action="click->repeater#add"、
// 各行の消すボタンは data-action="click->repeater#remove" で、消す対象は、そのボタンから
// いちばん近い data-repeater-target="row" の行。
//
// テンプレートの name/id/for に書いた __INDEX__ は、足すときに一意な値へ置き換える。
// 配列のパラメータは `[]` のまま使う(添字を振り直さない)ので、番号が連番である必要は無く、
// 同じ画面の中で衝突しないことだけが要る。消した行は、DOMから消えた時点で送られなくなる。
export default class extends Controller {
  static targets = ["template", "list", "row"]

  // テンプレートの印。テンプレート側にもこの綴りで書く。
  static PLACEHOLDER = "__INDEX__"

  add(event) {
    event.preventDefault()

    const row = this.templateTarget.content.cloneNode(true)
    const token = this.token()
    for (const element of row.querySelectorAll("[name], [id], [for]")) {
      this.replace(element, token)
    }
    this.listTarget.appendChild(row)
  }

  remove(event) {
    event.preventDefault()

    const row = event.target.closest("[data-repeater-target='row']")
    if (row) row.remove()
  }

  replace(element, token) {
    for (const name of ["name", "id", "for"]) {
      const value = element.getAttribute(name)
      if (value?.includes(this.constructor.PLACEHOLDER)) {
        element.setAttribute(name, value.replaceAll(this.constructor.PLACEHOLDER, token))
      }
    }
  }

  // 行を見分けるための一意な値。crypto.randomUUID が無い環境では、時刻と連番で代える。
  token() {
    if (crypto.randomUUID) return crypto.randomUUID()

    this.counter = (this.counter ?? 0) + 1
    return `${Date.now()}-${this.counter}`
  }
}
