import { Controller } from "@hotwired/stimulus"

// 手順①「PDFを読み取る」の、読むページの指定。1ページずつ見て、読まない・要件表・科目表の3択を選ばせ、
// 最後に一覧で確認させる(設計書 §6-1・§6-2)。
//
// サーバーは全ページぶんの行を HTML に出す。ここがするのは、1枚表示のときに、いまのページ以外を隠すことだけ。
// (遅延読み込みにしないのは、一覧への切り替えをサーバーへの往復なしで即座にするため。1枚表示と一覧の分岐をサーバー側に作らずに済む。
// 隠した行は hidden なので、ブラウザのページ内検索には掛からない。行の文字はページ番号と、画像が無いページの冒頭だけで、
// 検索の価値は小さいと見て、このままにしてある。必要になれば hidden="until-found" にすれば、検索も届く。)
//
// 種別の選択は、ラジオの値を書き換えるだけで、送信しない。保存は一覧の「この指定で読み取る」で1回だけ(Task 13 が作る)。
// そのため、選んだ結果は DOM のラジオが持つ。別に状態を持つと、保存される値と食い違う。
//
// 見せる/隠すは data-show の印で決める。値は wizard(1枚表示)・list(一覧)・nojs(JavaScript が無いとき)。
// 行は読み取りのたびに Turbo Stream で差し替わるので、差し替わった行にも同じ表示を当て直す(pageTargetConnected)。
export default class extends Controller {
  static targets = ["page", "counter", "summary", "list", "prev", "progress", "readCount"]

  // 左右で前後、1・2・3 で 読まない・要件表・科目表(PAGE_KINDS の並びと同じ)
  static KINDS = ["skip", "requirements", "courses"]
  static LABELS = { skip: "読まない", requirements: "要件表", courses: "科目表" }

  connect() {
    this.index = 0
    this.view = "wizard"
    // 「指定済み」は、このページで選んだものと、すでに読む種別になっているもの。初めはすべて「読まない」で、推測では決めない。
    this.decided = new Set(this.pageTargets.filter((row) => this.kindOf(row) !== "skip").map((row) => row.dataset.page))
    this.onKeydown = this.onKeydown.bind(this)
    document.addEventListener("keydown", this.onKeydown)
    this.ready = true
    this.render()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    this.ready = false
  }

  pageTargetConnected() {
    if (this.ready) this.render()
  }

  prev() {
    if (this.index > 0) this.go(this.index - 1)
  }

  // 最後のページの次は、一覧。
  next() {
    if (this.index < this.pageTargets.length - 1) this.go(this.index + 1)
    else this.showList()
  }

  showList() {
    this.view = "list"
    this.render()
    this.revealTop()
  }

  // 一覧の「直す」: そのページの1枚表示に戻る。
  edit(event) {
    const number = event.currentTarget.dataset.pageNumber
    const index = this.pageTargets.findIndex((row) => row.dataset.page === number)
    if (index >= 0) this.go(index)
  }

  // ラジオを押した。値はラジオ自身が持っているので、ここでは指定済みに数えて、次のページへ進むだけ。
  // (change ではなく click: すでに選ばれている「読まない」を、もう一度押しても進めるように)
  choose(event) {
    const row = event.currentTarget.closest("[data-page]")
    if (row) this.decided.add(row.dataset.page)
    this.next()
  }

  go(index) {
    this.index = index
    this.view = "wizard"
    this.render()
    this.revealTop()
  }

  onKeydown(event) {
    if (this.view !== "wizard" || event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return
    if (!this.listensTo(event.target)) return

    if (event.key === "ArrowLeft") this.prev()
    else if (event.key === "ArrowRight") this.next()
    else if (["1", "2", "3"].includes(event.key)) this.select(this.constructor.KINDS[Number(event.key) - 1])
    else return
    // ラジオの上では、矢印が選択の移動にも使われる。こちらの前後だけにする。
    event.preventDefault()
  }

  // 文字を打つ欄などの上では、キーを横取りしない。ラジオ・ボタンの上と、何も選んでいないときは受ける。
  listensTo(target) {
    if (!(target instanceof Element) || target === document.body) return true
    if (target.isContentEditable || target.closest("textarea, select")) return false
    const input = target.closest("input")
    if (input && !["radio", "checkbox", "button", "submit"].includes(input.type)) return false
    return this.element.contains(target)
  }

  // いまのページの種別を、キーボードで選ぶ。
  select(kind) {
    const row = this.pageTargets[this.index]
    const radio = row?.querySelector(`input[type=radio][value="${kind}"]`)
    if (!radio) return
    radio.checked = true
    this.decided.add(row.dataset.page)
    this.next()
  }

  kindOf(row) {
    return row.querySelector("input[type=radio]:checked")?.value || "skip"
  }

  render() {
    const total = this.pageTargets.length
    this.pageTargets.forEach((row, index) => {
      row.hidden = this.view === "wizard" && index !== this.index
      const label = row.querySelector("[data-page-wizard-target~=kindLabel]")
      if (label) label.textContent = this.constructor.LABELS[this.kindOf(row)]
    })
    this.element.querySelectorAll("[data-show]").forEach((element) => {
      element.hidden = !element.dataset.show.split(" ").includes(this.view)
    })

    const counts = { skip: 0, requirements: 0, courses: 0 }
    this.pageTargets.forEach((row) => { counts[this.kindOf(row)] += 1 })
    const current = this.pageTargets[this.index]
    if (this.hasCounterTarget) this.counterTarget.textContent = `${current ? current.dataset.page : 1}ページ目 / 全${total}ページ`
    if (this.hasProgressTarget) this.progressTarget.textContent = `${this.decided.size} / ${total}`
    if (this.hasPrevTarget) this.prevTarget.disabled = this.index === 0
    if (this.hasSummaryTarget) {
      this.summaryTarget.textContent = `要件表 ${counts.requirements} ・ 科目表 ${counts.courses} ・ 読まない ${counts.skip}`
    }
    if (this.hasReadCountTarget) this.readCountTarget.textContent = String(counts.requirements + counts.courses)
  }

  // 切り替えたとき、上の方が画面の外にあれば戻す(1枚が縦に長いので、次のページの頭が見えなくなる)。
  revealTop() {
    if (this.hasCounterTarget) this.element.scrollIntoView({ block: "nearest" })
  }
}
