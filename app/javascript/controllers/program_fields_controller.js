import { Controller } from "@hotwired/stimulus"

// 取り込みフォームの学部名・学科コース名。プルダウンで選び、「その他（新しく登録する）」を選んだときだけ、
// 自由入力欄を出す。学部を選ぶと、その学部の学科コースだけを残す(dependent-select と同じ作り)。
// 画面を開いた時点の選択(選んでいた組み合わせの引き継ぎ)は、そのまま残して、見え方だけを合わせる。
export default class extends Controller {
  static targets = ["faculty", "department", "newFaculty", "newDepartment"]
  static values = { other: String }

  connect() {
    this.sync()
  }

  sync() {
    const newFaculty = this.facultyTarget.value === this.otherValue
    this.filterDepartments(newFaculty)
    this.show(this.newFacultyTarget, newFaculty)
    this.show(this.newDepartmentTarget, this.departmentTarget.value === this.otherValue)
  }

  // 学科コースは <optgroup label="学部名"> で全部出してあり、選ばれた学部のものだけ残す。「その他」は常に残る。
  // 新しい学部には既存の学科コースが無いので、学科コースも「その他」に固定する。
  filterDepartments(newFaculty) {
    const faculty = this.facultyTarget.value
    for (const group of this.departmentTarget.querySelectorAll("optgroup")) {
      const matches = !newFaculty && group.label === faculty
      group.hidden = !matches
      group.disabled = !matches
    }

    if (newFaculty) {
      this.departmentTarget.value = this.otherValue
      this.forcedOther = true
      return
    }
    // 新しい学部をやめて既存の学部に戻したら、こちらで固定した「その他」は外す(選び直してもらう)
    if (this.forcedOther) {
      this.forcedOther = false
      if (this.departmentTarget.value === this.otherValue) this.departmentTarget.value = ""
    }
    // 隠れた学部の学科コースが選ばれたままにならないようにする
    const chosen = this.departmentTarget.selectedOptions[0]
    if (chosen && chosen.parentElement.disabled) this.departmentTarget.value = ""
  }

  // 隠れている欄は入力を求めない(隠れた必須欄は、送信を黙って止めてしまう)。
  show(wrapper, visible) {
    wrapper.hidden = !visible
    wrapper.querySelector("input").required = visible
  }
}
