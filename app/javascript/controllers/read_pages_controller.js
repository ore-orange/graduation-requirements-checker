import { Controller } from "@hotwired/stimulus"

// 便覧の下書きの「読むページ」。1ページずつ読み取りを頼み、そのページの行だけを Turbo Stream で差し替える。
// 読み取りは外部APIの呼び出しで1ページ数秒〜数十秒かかり、無料枠には1分あたりの上限もあるので、
// 「全部読む」は、1ページ終わってから次を頼む(並べて投げない)。要件表を先に読む。区分は要件表で決まり、科目表が使うため。
// 1ページの読み取りは、窓口の再試行(3回、待ちは最大60秒)を含めて数分かかりうる。それより長く待って止まっているなら、
// 画面を「読み取っています」のまま、ボタンを使えないままにしないため、こちらから切る(サーバー側の読み取りは続き、結果は行に残る)。
const READ_TIMEOUT_MS = 10 * 60 * 1000

export default class extends Controller {
  static targets = ["all", "one", "message"]

  readOne(event) {
    const row = event.currentTarget.closest("[data-read-url]")
    return this.readRows([row])
  }

  // 読み終わっていない(未読か失敗)、読む種別のページを、要件表 → 科目表の順に、ページ番号順で読む。
  readAll() {
    const rows = [...this.element.querySelectorAll("[data-read-url]")].filter((row) => row.dataset.status !== "read")
    const requirements = rows.filter((row) => row.dataset.kind === "requirements")
    const others = rows.filter((row) => row.dataset.kind !== "requirements")
    return this.readRows([...requirements, ...others])
  }

  async readRows(rows) {
    if (this.busy || rows.length === 0) return
    // 人が直した規則・章・行があるページは、読み直す前に、何が残り何が入れ替わるかを見せる(サーバーが文を作る)。
    const warnings = rows.map((row) => row.dataset.rereadWarning).filter(Boolean)
    if (warnings.length > 0 && !window.confirm(warnings.join("\n\n"))) return
    // 行は読むたびに差し替わるので、先に必要なものを取っておく。
    const jobs = rows.map((row) => ({ page: row.dataset.page, url: row.dataset.readUrl }))
    this.setBusy(true)
    let failed = 0
    for (const [index, job] of jobs.entries()) {
      this.show(`${job.page}ページを読み取っています(${index + 1}/${jobs.length})。このまましばらくお待ちください。`)
      if (!(await this.read(job))) failed += 1
    }
    this.setBusy(false)
    let message = failed === 0 ? "読み取りが終わりました。" : `読み取りが終わりました(${failed}ページは読めませんでした。行の表示を確認してください)。`
    // 下の要件表と注釈は、このページを開いたときの内容のまま。読み取った結果を見るには、開き直す必要がある。
    // (古い表のまま直しても、保存のときに弾かれる。中身を取り違えて書き込むことはない)
    if (failed < jobs.length) message += "要件表と注釈の表示は古いままです。ページを開き直すと、読み取った結果が出ます。"
    this.show(message)
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
    const buttons = [...this.oneTargets, ...this.allTargets]
    buttons.forEach((button) => { button.disabled = busy })
  }

  show(message) {
    this.messageTarget.textContent = message
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
