import { Controller } from "@hotwired/stimulus"

// 決まった値を選べて、一覧にない値も打ち込める欄。
// 欄を押すと候補が出る。打つと候補を絞り込む。候補は目安で、入力は制限しない。
export default class extends Controller {
  static targets = ["input", "list", "option"]

  // 欄を開いたときは絞り込まない。今の値が候補にない(直したい)ときこそ、全部見せる。
  open() {
    this.optionTargets.forEach((option) => { option.hidden = false })
    this.listTarget.hidden = false
  }

  close() {
    this.listTarget.hidden = true
    this.highlight(null)
  }

  // 打っている間だけ、その文字を含む候補に絞る。残らなければ一覧は出さない。
  filter() {
    this.listTarget.hidden = false
    const text = this.inputTarget.value.trim()
    this.optionTargets.forEach((option) => {
      option.hidden = text !== "" && !option.dataset.value.includes(text)
    })
    if (this.visibleOptions().length === 0) this.listTarget.hidden = true
  }

  pick(event) {
    event.preventDefault()
    this.inputTarget.value = event.currentTarget.dataset.value
    this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.close()
    this.inputTarget.focus()
  }

  // 欄から出たら閉じる。候補を押したときは pick が先に動くので閉じて構わない。
  closeOnLeave(event) {
    if (!this.element.contains(event.relatedTarget)) this.close()
  }

  keydown(event) {
    if (event.key === "Escape") return this.close()
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      if (this.listTarget.hidden) return this.open()
      return this.move(event.key === "ArrowDown" ? 1 : -1)
    }
    if (event.key === "Enter" && this.highlighted()) {
      event.preventDefault()
      this.inputTarget.value = this.highlighted().dataset.value
      this.close()
    }
  }

  move(step) {
    const options = this.visibleOptions()
    if (options.length === 0) return

    const index = options.indexOf(this.highlighted())
    const next = index === -1 ? (step > 0 ? 0 : options.length - 1) : (index + step + options.length) % options.length
    this.highlight(options[next])
  }

  highlight(option) {
    this.optionTargets.forEach((item) => item.classList.toggle("bg-slate-200", item === option))
    if (option) option.scrollIntoView({ block: "nearest" })
  }

  highlighted() {
    return this.optionTargets.find((option) => option.classList.contains("bg-slate-200")) || null
  }

  visibleOptions() {
    return this.optionTargets.filter((option) => !option.hidden)
  }
}
