import { Controller } from "@hotwired/stimulus"

// ダッシュボードのゲージのツールチップ。マウスカーソルのすぐ右下に出す。
// popover（最前面のレイヤー）に出すので、親の overflow-hidden や重なり順に隠されない。
export default class extends Controller {
  static targets = ["tip"]

  // カーソルからツールチップまでの距離(px)
  static OFFSET = 12

  show(event) {
    if (!this.hasTipTarget) return

    if (!this.tipTarget.matches(":popover-open")) this.tipTarget.showPopover()
    this.move(event)
  }

  move(event) {
    if (!this.hasTipTarget) return

    const tip = this.tipTarget
    const offset = this.constructor.OFFSET
    // 画面の右端・下端からはみ出すときは、カーソルの左・上に回す
    let left = event.clientX + offset
    let top = event.clientY + offset
    if (left + tip.offsetWidth > window.innerWidth) left = event.clientX - offset - tip.offsetWidth
    if (top + tip.offsetHeight > window.innerHeight) top = event.clientY - offset - tip.offsetHeight
    tip.style.left = `${Math.max(0, left)}px`
    tip.style.top = `${Math.max(0, top)}px`
  }

  hide() {
    if (this.hasTipTarget && this.tipTarget.matches(":popover-open")) this.tipTarget.hidePopover()
  }

  disconnect() {
    this.hide()
  }
}
