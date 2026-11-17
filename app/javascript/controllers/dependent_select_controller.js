import { Controller } from "@hotwired/stimulus"
import OptionGroups from "controllers/option_groups"

// 親の選択(学部)に合わせて、子の選択肢(学科)を絞る。
// 子には全学科を <optgroup label="学部名"> で出しておき、選ばれた学部のものだけ残す
// (残し方は OptionGroups に任せる。hidden では消えないブラウザがあるため、DOM から外す)。
export default class extends Controller {
  static targets = ["parent", "child"]

  connect() {
    this.groups = new OptionGroups(this.childTarget)
    this.filter()
  }

  disconnect() {
    this.groups.restore()
  }

  filter() {
    // 親の値は id なので、optgroup の label と合わせるのに表示名を使う。
    const visible = this.groups.keep(this.parentTarget.selectedOptions[0]?.text)

    this.childTarget.disabled = visible === 0
  }
}
