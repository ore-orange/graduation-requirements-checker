import { Controller } from "@hotwired/stimulus"

// 章・枠・行の並び替え。この入れ物の直接の子(data-reorder-target="item")を、1つ上・下に動かす。
//
// 並びは「送られた順」で伝わる(DisplayEditing#merge_in_order が id で突き合わせ、送られた順に並べる)ので、
// DOM の要素を入れ替えるだけでよく、「並び(小さい順)」の数字の欄は要らない。
// 欄の名前の添字は振り直さない(添字は要素を見分けるためだけに使われ、連番である必要が無い)。
//
// ツリーなので、入れ物は入れ子になる(章の中に枠、枠の中に行)。扱うのは直接の子だけにして、
// 内側の入れ物の要素は内側に任せる(同じ名前のコントローラが入れ子になっても、二重に動かさない)。
export default class extends Controller {
  up(event) {
    this.move(event, -1)
  }

  down(event) {
    this.move(event, 1)
  }

  move(event, step) {
    event.preventDefault()

    const items = [...this.element.children].filter((child) => child.matches("[data-reorder-target='item']"))
    const item = event.target.closest("[data-reorder-target='item']")
    const index = items.indexOf(item)
    if (index < 0) return // 内側の入れ物の要素。その入れ物が受け持つ

    const other = items[index + step]
    if (!other) return

    if (step < 0) other.before(item)
    else other.after(item)
    event.target.focus()
  }
}
