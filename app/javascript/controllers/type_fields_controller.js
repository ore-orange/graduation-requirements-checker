import { Controller } from "@hotwired/stimulus"

// 種類を選ぶと、その種類が持つ欄だけを出す(規則を足すフォーム)。
// 種類ごとの欄は全部その場に出してあり、選ばれていない種類の欄は隠したうえで disabled にする。
// 隠しただけだと値が送られ、選んだ種類に無い欄まで一緒に届いてしまう。
// JavaScript が動かないときは、どの種類の欄も見えたまま。選んだ種類の欄に書けば、保存はできる。
export default class extends Controller {
  static targets = ["select", "block"]

  connect() {
    this.sync()
  }

  sync() {
    const chosen = this.selectTarget.value
    for (const block of this.blockTargets) {
      const matches = block.dataset.type === chosen
      block.hidden = !matches
      for (const field of block.querySelectorAll("input, select, textarea")) {
        field.disabled = !matches
      }
    }
  }
}
