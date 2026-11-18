import { Controller } from "@hotwired/stimulus"
import OptionGroups from "controllers/option_groups"

// 取り込みフォームの学部名・学科名・コース名。プルダウンで選び、「その他（新しく登録する）」を選んだときだけ、
// 自由入力欄を出す。学部を選ぶとその学部の学科だけを残す(dependent-select と同じ作り)。
// 学科を選ぶと、その学科のコースだけを残す。コースが1件も無い学科(または学科が決まっていない・新しい学科)を
// 選んだときは、コースの欄自体を隠す(選ばせても意味が無い。隠れた欄の値は送らない)。
// 画面を開いた時点の選択(選んでいた組み合わせの引き継ぎ)は、そのまま残して、見え方だけを合わせる。
export default class extends Controller {
  static targets = ["faculty", "department", "course", "courseField", "newFaculty", "newDepartment", "newCourse"]
  static values = { other: String }

  connect() {
    this.departments = new OptionGroups(this.departmentTarget)
    this.courses = new OptionGroups(this.courseTarget)
    this.sync()
  }

  disconnect() {
    this.departments.restore()
    this.courses.restore()
  }

  sync() {
    const newFaculty = this.facultyTarget.value === this.otherValue
    this.filterDepartments(newFaculty)
    this.show(this.newFacultyTarget, newFaculty)

    const newDepartment = this.departmentTarget.value === this.otherValue
    this.show(this.newDepartmentTarget, newDepartment)
    this.filterCourses(newDepartment)
    this.show(this.newCourseTarget, this.courseTarget.value === this.otherValue)
  }

  // 学科コースは <optgroup label="学部名"> で全部出してあり、選ばれた学部のものだけ残す
  // (OptionGroups が合わない optgroup を DOM から外す)。<optgroup> の外にある「その他」は常に残る。
  // 新しい学部には既存の学科が無いので、学科も「その他」に固定する。
  filterDepartments(newFaculty) {
    this.departments.keep(newFaculty ? null : this.facultyTarget.value)

    if (newFaculty) {
      this.departmentTarget.value = this.otherValue
      this.forcedOtherDepartment = true
      return
    }
    // 新しい学部をやめて既存の学部に戻したら、こちらで固定した「その他」は外す(選び直してもらう)
    if (this.forcedOtherDepartment) {
      this.forcedOtherDepartment = false
      if (this.departmentTarget.value === this.otherValue) this.departmentTarget.value = ""
    }
  }

  // コースは <optgroup label="学科名"> で全部出してあり、選ばれた学科のものだけ残す。学科が決まっていない・
  // 新しい学科・コースの無い学科のときは、コースの欄自体を隠し、値も空に戻す(隠れた欄の値を黙って送らない)。
  filterCourses(newDepartment) {
    const department = this.departmentTarget.value
    const anyCourse = this.courses.keep(newDepartment ? null : department) > 0

    this.show(this.courseFieldTarget, !newDepartment && department && anyCourse)
    if (newDepartment || !department || !anyCourse) this.courseTarget.value = ""
  }

  // 隠れている欄は入力を求めない(隠れた必須欄は、送信を黙って止めてしまう)。
  show(wrapper, visible) {
    wrapper.hidden = !visible
    const input = wrapper.querySelector("input")
    if (input) input.required = visible
  }
}
