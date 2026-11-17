import { Controller } from "@hotwired/stimulus"
import OptionGroups from "controllers/option_groups"

// 対象を選ぶ画面(卒業要件の確認)の学部・学科・コース。親の選択に合わせて、子の選択肢を絞る。
//
// 作りは取り込みフォームの program-fields と同じ。学科は <optgroup label="学部名">、コースは
// <optgroup label="学科名"> で全部描いてあり、親に合わない optgroup を OptionGroups が DOM から外す。
// サーバは全選択肢を描くので、JavaScript が動かなければ全選択肢から選べ、学部・学科・コースの
// 入った URL を直接開いても選択は残る(_selector.html.erb 冒頭の約束)。
//
// 親が選ばれていないときは、子は「---------」だけになる。
// 取り込みフォームと違い、ここには「その他(新しく登録する)」が無いので、自由入力欄の出し入れはしない。
export default class extends Controller {
  static targets = ["faculty", "department", "course"]

  connect() {
    this.departments = new OptionGroups(this.departmentTarget)
    this.courses = new OptionGroups(this.courseTarget)
    this.sync()
  }

  disconnect() {
    this.departments.restore()
    this.courses.restore()
  }

  // 学部→学科→コースの順に絞る。学科の選択が消えたら、その値でコースを絞る(順番を入れ替えない)。
  sync() {
    this.departments.keep(this.facultyTarget.value)
    this.courses.keep(this.departmentTarget.value)
  }
}
