import { Controller } from "@hotwired/stimulus"

// 対象を選ぶ画面(卒業要件の確認)の学部・学科・コース。親の選択に合わせて、子の選択肢を絞る。
//
// 作りは取り込みフォームの program-fields と同じ。学科は <optgroup label="学部名">、コースは
// <optgroup label="学科名"> で全部描いてあり、親に合わない optgroup を hidden/disabled にするだけ。
// 選択肢そのものは減らさないので、JavaScript が動かなければ全選択肢から選べ、学部・学科・コースの
// 入った URL を直接開いても選択は残る(_selector.html.erb 冒頭の約束)。
//
// 親が選ばれていないときは、子は「---------」だけになる。
// 取り込みフォームと違い、ここには「その他(新しく登録する)」が無いので、自由入力欄の出し入れはしない。
export default class extends Controller {
  static targets = ["faculty", "department", "course"]

  connect() {
    this.sync()
  }

  // 学部→学科→コースの順に絞る。学科の選択が消えたら、その値でコースを絞る(順番を入れ替えない)。
  sync() {
    this.filter(this.departmentTarget, this.facultyTarget.value)
    this.filter(this.courseTarget, this.departmentTarget.value)
  }

  // 親の値と label が合う optgroup だけを残す。親が選ばれていなければ、どれも残さない。
  // 隠れた optgroup の選択肢が選ばれたままなら、選択を空に戻す(見えない値を黙って送らない)。
  filter(select, parent) {
    for (const group of select.querySelectorAll("optgroup")) {
      const matches = Boolean(parent) && group.label === parent
      group.hidden = !matches
      group.disabled = !matches
    }

    if (select.selectedOptions[0]?.parentElement?.disabled) select.value = ""
  }
}
