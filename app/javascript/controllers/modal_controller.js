import { Controller } from "@hotwired/stimulus"

// <dialog> をボタンで開閉する。背景のクリックでも閉じる。
export default class extends Controller {
  static targets = ["dialog"]

  open() {
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  closeOnBackdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }
}
