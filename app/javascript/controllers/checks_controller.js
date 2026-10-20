import { Controller } from "@hotwired/stimulus"

// 「確認済み」のチェックボックスを扱う。
// - 見出しのチェックで、このページの全行を入れ外しする
// - チェックの入れ外しをブラウザ(sessionStorage)に覚え、ページを移動しても復元する
// - 更新するときは、ほかのページで覚えているチェックも一緒に送る(remembered[行ID]=1/0)
// 入力した値(編集内容)は覚えない。更新を押したページの分だけ保存される。
export default class extends Controller {
  static targets = ["box", "all"]
  static values = { key: String }

  connect() {
    this.restore = this.restore.bind(this)
    document.addEventListener("turbo:morph", this.restore)
    this.restore()
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.restore)
  }

  toggle(event) {
    this.remember(event.target)
    this.syncAll()
  }

  toggleAll() {
    this.boxTargets.forEach((box) => {
      box.checked = this.allTarget.checked
      this.remember(box)
    })
    this.syncAll()
  }

  // 送信の直前に、画面にない行の覚えているチェックを hidden で足す。送ったら覚えは捨てる(サーバーが正になる)
  submit() {
    this.element.querySelectorAll("input[data-remembered]").forEach((input) => input.remove())
    const onPage = new Set(this.boxTargets.map((box) => box.dataset.rowId))
    Object.entries(this.load()).forEach(([id, checked]) => {
      if (onPage.has(id)) return
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = `remembered[${id}]`
      input.value = checked ? "1" : "0"
      input.dataset.remembered = "true"
      this.element.appendChild(input)
    })
    this.save({})
  }

  restore() {
    const saved = this.load()
    this.boxTargets.forEach((box) => {
      if (Object.prototype.hasOwnProperty.call(saved, box.dataset.rowId)) box.checked = saved[box.dataset.rowId]
    })
    this.syncAll()
  }

  remember(box) {
    const saved = this.load()
    saved[box.dataset.rowId] = box.checked
    this.save(saved)
  }

  syncAll() {
    if (!this.hasAllTarget) return
    const checked = this.boxTargets.filter((box) => box.checked).length
    this.allTarget.checked = checked > 0 && checked === this.boxTargets.length
    this.allTarget.indeterminate = checked > 0 && checked < this.boxTargets.length
  }

  load() {
    try {
      return JSON.parse(sessionStorage.getItem(this.keyValue) || "{}")
    } catch (error) {
      return {}
    }
  }

  save(saved) {
    try {
      sessionStorage.setItem(this.keyValue, JSON.stringify(saved))
    } catch (error) {
      // 保存できない環境(プライベートウィンドウなど)では、覚えずに続ける
    }
  }
}
