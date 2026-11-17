import { Controller } from "@hotwired/stimulus"

// 便覧の下書きの「読むページ」。1ページずつ読み取りを頼み、そのページの行だけを Turbo Stream で差し替える。
// 読み取りは外部APIの呼び出しで1ページ数秒〜数十秒かかり、無料枠には1分あたりの上限もあるので、
// 「全部読む」は、1ページ終わってから次を頼む(並べて投げない)。要件表を先に読む。区分は要件表で決まり、科目表が使うため。
// 1ページの読み取りは、窓口の再試行(3回、待ちは最大60秒)を含めて数分かかりうる。それより長く待って止まっているなら、
// 画面を「読み取っています」のまま、ボタンを使えないままにしないため、こちらから切る(サーバー側の読み取りは続き、結果は行に残る)。
const READ_TIMEOUT_MS = 10 * 60 * 1000
// 読み取りの間、触れなくする節。古い内容のまま触れると、保存で弾かれる。
const LOCKED_SECTIONS = ["requirements_review", "course-review", "publish"]

export default class extends Controller {
  static targets = ["all", "one", "commit", "message", "progressBox", "bar", "count", "elapsed", "done", "heading"]

  // 画面を離れたあとも、タイマーと inert を残さない。Turbo は遷移の前(turbo:before-cache)の画面を保存し、「戻る」でそれを復元する。
  // 読み取りの途中の見た目(inert・薄い見た目・進捗の箱)のまま保存されると、復元した画面で②③④が触れないまま残る。
  // 復元された画面は、必ず触れる状態から始める(connect)。
  connect() {
    this.connected = true
    this.beforeCache = this.beforeCache.bind(this)
    this.onPageShow = (event) => { if (event.persisted) this.resetReadingState() }
    document.addEventListener("turbo:before-cache", this.beforeCache)
    // Turbo を通らない遷移で離れた画面を「戻る」で復元したとき(bfcache)は、connect が走らないので、ここで整える。
    window.addEventListener("pageshow", this.onPageShow)
    this.resetReadingState()
  }

  disconnect() {
    this.connected = false
    document.removeEventListener("turbo:before-cache", this.beforeCache)
    window.removeEventListener("pageshow", this.onPageShow)
    this.stopTimer()
  }

  beforeCache() {
    this.stopTimer()
    this.resetReadingState()
  }

  resetReadingState() {
    this.lockSections(false)
    if (this.hasProgressBoxTarget) this.progressBoxTarget.hidden = true
    if (this.hasDoneTarget) this.doneTarget.hidden = true
  }

  readOne(event) {
    const row = event.currentTarget.closest("[data-read-url]")
    return this.readRows([row])
  }

  // 一覧の「この指定で読み取る」と、「全部読む」。保存してから読む(順を逆にしない)。
  // 1ページ読むたびにその行が差し替わり、そのとき保存していないラジオの選択は保存値に戻る。先に読み始めると、人が選んだ指定が消える。
  // 警告(読み取り結果を外す・人が直したものがあるページを読み直す)は、保存の応答がサーバーの保存済みの内容から作って返す。
  // 保存前の状態から画面で作ると、同じ判断を画面にも持つことになる。
  // 読むのは、読み終わっていない(未読か失敗)、読む種別のページを、要件表 → 科目表の順に、ページ番号順で。
  async saveAndRead() {
    if (this.busy) return
    this.setBusy(true)
    this.clearDone()
    this.show("ページの指定を保存しています…")
    const saved = await this.save()
    if (!saved) return this.setBusy(false)

    // 読む種別のページが無ければ、読み取りを始めない(0ページの読み取りはしない)。
    const rows = this.rowsToRead()
    if (this.readableRows().length === 0) {
      this.show(["ページの指定を保存しました。読み取るページ(要件表・科目表)が選ばれていないので、読み取りは始めませんでした。", ...saved.warnings].join("\n"))
      return this.setBusy(false)
    }
    if (rows.length === 0) {
      this.show("ページの指定を保存しました。読むページはすべて読み取り済みです。読み直すときは、行の「読み直す」を押してください。")
      return this.setBusy(false)
    }
    if (saved.warnings.length > 0 && !window.confirm(saved.warnings.join("\n\n"))) {
      this.show("ページの指定は保存しました。読み取りは始めませんでした。")
      return this.setBusy(false)
    }
    this.setBusy(false)
    // 確認は済んでいるので、行ごとの確認は出さない。
    return this.readRows(rows, { confirmed: true })
  }

  // フォームの pages[...] を PATCH する。成功したら { warnings } を返す。失敗したら理由を一覧の上に出して false を返す。
  async save() {
    const form = this.element.querySelector("form")
    try {
      const response = await fetch(form.action, {
        method: "PATCH",
        credentials: "same-origin",
        body: new FormData(form),
        headers: { "X-CSRF-Token": this.csrfToken(), Accept: "text/vnd.turbo-stream.html" },
      })
      const type = response.headers.get("Content-Type") || ""
      if (!type.includes("turbo-stream")) {
        this.show(`ページの指定を保存できませんでした(HTTP ${response.status})。読み取りは始めませんでした。ページを開き直して確認してください。`)
        return false
      }
      const body = await response.text()
      const warnings = this.warningsIn(body)
      await this.render(body)
      if (!response.ok) {
        this.show("ページの指定を保存できませんでした。")
        return false
      }
      this.show("")
      return { warnings }
    } catch (error) {
      this.show("ページの指定を保存できませんでした(通信に失敗しました)。読み取りは始めませんでした。")
      return false
    }
  }

  // 応答の Turbo Stream が持つ、保存結果の警告(JSON の配列)。
  warningsIn(body) {
    const template = document.createElement("template")
    template.innerHTML = body
    // 中身は <turbo-stream> の中の <template> にあり、その content は別の断片なので、そちらを探す。
    const holder = [...template.content.querySelectorAll("template")]
      .map((inner) => inner.content.querySelector("[data-save-warnings]"))
      .find(Boolean)
    try {
      const list = JSON.parse(holder?.dataset.saveWarnings || "[]")
      return Array.isArray(list) ? list.filter(Boolean) : []
    } catch (error) {
      return []
    }
  }

  // Turbo Stream を当て、行が差し替わるまで待つ(Turbo は次の描画で当て、終わると turbo-stream 要素を取り除く)。
  async render(body) {
    window.Turbo.renderStreamMessage(body)
    for (let tries = 0; tries < 100 && document.querySelector("turbo-stream"); tries += 1) {
      await new Promise((resolve) => setTimeout(resolve, 20))
    }
  }

  rows() {
    return [...this.element.querySelectorAll("[data-page]")]
  }

  // 読む種別の行(要件表・科目表)
  readableRows() {
    return this.rows().filter((row) => row.dataset.kind !== "skip")
  }

  // 読み終わっていない、読む種別の行を、要件表 → 科目表の順に、ページ番号順で。
  rowsToRead() {
    const rows = [...this.element.querySelectorAll("[data-read-url]")].filter((row) => row.dataset.status !== "read")
    const requirements = rows.filter((row) => row.dataset.kind === "requirements")
    const others = rows.filter((row) => row.dataset.kind !== "requirements")
    return [...requirements, ...others]
  }

  async readRows(rows, { confirmed = false } = {}) {
    if (this.busy || rows.length === 0) return
    // 人が直した規則・章・行があるページは、読み直す前に、何が残り何が入れ替わるかを見せる(サーバーが文を作る)。
    // 「この指定で読み取る」は、保存の応答で見せ終わっている。
    const warnings = confirmed ? [] : rows.map((row) => row.dataset.rereadWarning).filter(Boolean)
    if (warnings.length > 0 && !window.confirm(warnings.join("\n\n"))) return
    // 行は読むたびに差し替わるので、先に必要なものを取っておく。
    const jobs = rows.map((row) => ({ page: row.dataset.page, url: row.dataset.readUrl }))
    this.setBusy(true)
    this.clearDone()
    this.lockSections(true)
    this.headingTarget.textContent = "読み取り中"
    this.progressBoxTarget.hidden = false
    let failed = 0
    try {
      for (const [index, job] of jobs.entries()) {
        this.progress(index, jobs.length, job.page)
        if (!(await this.read(job))) failed += 1
      }
    } finally {
      this.stopTimer()
      // 読み取りの途中で画面を離れていれば、触れる画面はもう無い(復元された画面は connect が整える)。
      if (this.connected) this.finishReading(jobs.length, failed)
    }
  }

  // 終わりの後始末。例外で抜けたときも通る(秒数や「読み取り中」を残さない)。
  finishReading(total, failed) {
    this.progress(total, total)
    this.headingTarget.textContent = "読み取り済み"
    this.elapsedTarget.textContent = ""
    this.lockSections(false)
    this.setBusy(false)
    let message = failed === 0 ? "読み取りが終わりました。" : `読み取りが終わりました(${failed}ページは読めませんでした。行の表示を確認してください)。`
    if (failed < total) message += "読み取った結果は、画面を開き直すと下の節に出ます。"
    this.show(message)
    // 下の要件表と注釈は、このページを開いたときの内容のまま。読み取った結果を見るには、開き直す必要がある。
    // (古い表のまま直しても、保存のときに弾かれる。中身を取り違えて書き込むことはない)
    if (failed < total) this.doneTarget.hidden = false
  }

  // 「要件表の確認へ」: 画面を開き直して②へ飛ぶ。
  openReview() {
    window.location.hash = "requirements_review"
    window.location.reload()
  }

  clearDone() {
    this.doneTarget.hidden = true
  }

  // 進み具合: バーと「n / m ページ」。page があれば、そのページの経過秒数を1秒ごとに更新する(1ページで数十秒かかっても止まって見えない)。
  progress(done, total, page = null) {
    this.stopTimer()
    this.barTarget.max = total
    this.barTarget.value = done
    this.countTarget.textContent = `${done} / ${total} ページ`
    if (page === null) return
    const startedAt = Date.now()
    const tick = () => {
      const seconds = Math.floor((Date.now() - startedAt) / 1000)
      this.elapsedTarget.textContent = `${page}ページを読み取っています…(${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")})`
    }
    tick()
    this.timer = setInterval(tick, 1000)
  }

  stopTimer() {
    clearInterval(this.timer)
    this.timer = null
  }

  // 読み取り中は、②③④の節を触れなくして薄くし、理由を添える。終われば外す。
  lockSections(locked) {
    LOCKED_SECTIONS.map((id) => document.getElementById(id)).filter(Boolean).forEach((section) => {
      section.toggleAttribute("inert", locked)
      section.classList.toggle("opacity-50", locked)
      section.querySelector(":scope > [data-reading-note]")?.remove()
      if (!locked) return
      const note = document.createElement("p")
      note.dataset.readingNote = ""
      note.className = "px-5 pt-3 text-sm font-semibold text-slate-800 sm:px-6"
      note.textContent = "読み取りが終わると出ます。"
      section.prepend(note)
    })
  }

  // 1ページ読む。行の差し替えは返ってきた Turbo Stream に任せる。
  async read({ page, url }) {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), READ_TIMEOUT_MS)
    try {
      const response = await fetch(url, {
        signal: controller.signal,
        method: "POST",
        credentials: "same-origin",
        headers: { "X-CSRF-Token": this.csrfToken(), Accept: "text/vnd.turbo-stream.html" },
      })
      const type = response.headers.get("Content-Type") || ""
      if (!type.includes("turbo-stream")) {
        this.show(`${page}ページを読み取れませんでした(HTTP ${response.status})。`)
        return false
      }
      window.Turbo.renderStreamMessage(await response.text())
      // 読めたかどうかは、差し替えた行が持つ(失敗の理由もそこに出る)。
      return response.ok
    } catch (error) {
      const timedOut = error.name === "AbortError"
      this.show(timedOut ? `${page}ページの読み取りが長引いたため待つのをやめました。ページを開き直して、行の表示を確認してください。` : `${page}ページの読み取りで通信に失敗しました。`)
      return false
    } finally {
      clearTimeout(timer)
    }
  }

  setBusy(busy) {
    this.busy = busy
    const buttons = [...this.oneTargets, ...this.allTargets, ...this.commitTargets]
    // 読み取りができないとき(APIキーが無い)に使えないままのボタンを、読み取りが終わっても使えるようにしない。
    if (busy) this.disabledBefore = new Map(buttons.map((button) => [button, button.disabled]))
    buttons.forEach((button) => { button.disabled = busy || Boolean(this.disabledBefore?.get(button)) })
  }

  show(message) {
    this.messageTarget.textContent = message
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
