// プルダウン(<select>)の <optgroup> を、親で選んだものだけに絞る小さな道具。
//
// hidden と disabled を付けるだけでは足りない。<optgroup>/<option> の hidden を無視するブラウザ
// (Safari など)があり、そこでは他の学部の学科がプルダウンに並んだままになる。確実に消えるよう、
// 合わない <optgroup> は DOM から外す。戻す場所にコメントを置いておき、元の位置へ戻す。
//
// サーバは全選択肢を描くので、JavaScript が動かないときは今までどおり全部から選べる
// (絞り込みは画面の中だけの話で、選択肢そのものは減らさない)。
export default class OptionGroups {
  constructor(select) {
    this.select = select
    this.groups = Array.from(select.querySelectorAll("optgroup"))
      .map((group) => ({ group, slot: document.createComment(group.label) }))
  }

  // label と合う <optgroup> だけを残し、残った選択肢の数を返す。label が空なら、どれも残さない。
  // 外した <optgroup> の中身が選ばれていたときは、ブラウザが先頭(---------)に戻すので、
  // 見えない値が黙って送られることはない。
  keep(label) {
    let kept = 0
    for (const { group, slot } of this.groups) {
      if (label && group.label === label) {
        if (!group.isConnected) slot.replaceWith(group)
        kept += group.children.length
      } else if (group.isConnected) {
        group.replaceWith(slot)
      }
    }
    return kept
  }

  // 外した <optgroup> を全部戻す。コントローラが外れるとき(Turbo の差し替えなど)に、
  // DOM を元の形へ返しておくために使う。
  restore() {
    for (const { group, slot } of this.groups) {
      if (!group.isConnected) slot.replaceWith(group)
    }
  }
}
