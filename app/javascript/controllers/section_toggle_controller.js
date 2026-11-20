import { Controller } from "@hotwired/stimulus"

// 科目表の区分の節の開閉(設計書 項目6)。
//
// 2024年度の実データは484科目あり、全部広げると科目表だけで約28画面分になる。見出しだけを並べ、見たい区分を開く。
//
// 節は1つの <table> の中の <tbody> で、上に PDF ペインの貼り付く行があるため <details> では囲めない。
// そこで、同じ data-section を持つ <tbody> の hidden を出し入れする。
//
// 畳んだ状態はサーバーが描く(hidden 付き)。JavaScript が動かないと開けなくなるので、
// 画面側に <noscript> の style を置いて、その場合は全部開いた状態に戻す(_courses_review.html.erb)。
export default class extends Controller {
  toggle(event) {
    const button = event.currentTarget
    const key = button.dataset.section
    if (!key) return

    const open = button.getAttribute("aria-expanded") !== "true"
    button.setAttribute("aria-expanded", String(open))

    const mark = button.querySelector("[data-section-toggle-mark]")
    if (mark) mark.textContent = open ? "▾" : "▸"

    this.element.querySelectorAll(`tbody[data-section="${CSS.escape(key)}"]`).forEach((body) => {
      body.hidden = !open
    })
  }
}
