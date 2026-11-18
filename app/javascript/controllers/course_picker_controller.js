import { Controller } from "@hotwired/stimulus"

// 経路に足す科目を選ぶ2段の選択(設計書 項目3-1)。
//
// 2024年度は484科目あるので、1つの選択肢には並べられない。先に区分を選び、その区分の科目だけを出す。
//
// 科目の選択肢は、区分ごとに <optgroup data-category> を付けてサーバーが全部描いている。
// ここでやるのは、選ばれていない区分の optgroup を隠すことだけ。JavaScript が動かなければ
// 全部の区分から選べる(絞り込みが効かないだけで、選んで保存はできる)。
export default class extends Controller {
  static targets = ["category", "course"]

  connect() {
    this.apply("")
  }

  pick() {
    this.apply(this.categoryTarget.value)
  }

  apply(category) {
    const groups = this.courseTarget.querySelectorAll("optgroup[data-category]")
    groups.forEach((group) => {
      group.hidden = category !== "" && group.dataset.category !== category
      group.disabled = group.hidden
    })
    // 隠した区分の科目が選ばれたままにならないよう、選択を先頭(「科目を選んでください」)へ戻す。
    const chosen = this.courseTarget.selectedOptions[0]
    if (chosen && chosen.parentElement.hidden) this.courseTarget.selectedIndex = 0
  }
}
