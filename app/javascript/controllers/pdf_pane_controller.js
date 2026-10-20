import { Controller } from "@hotwired/stimulus"

// 取り込んだPDFを見比べるペイン。自分でスクロールして見る。
// 既定は「幅に合わせる」。倍率を変えても、まん中に見えていたところがまん中に残る。
// 状態は倍率の入力欄だけに持つので、turbo:morph で作り直されても困らない。
export default class extends Controller {
  static targets = ["pane", "hidden", "headRow", "scroll", "page", "zoom", "zoomValue"]
  // ページ画像の実寸(横幅px)。画像の読み込みを待たずに倍率を決められるよう、サーバーから受け取る。
  static values = { pageWidth: Number }

  connect() {
    this.stick = this.stick.bind(this)
    this.observer = new ResizeObserver(this.stick)
    this.observer.observe(this.scrollTarget)
    this.fit()
    this.stick()
  }

  disconnect() {
    this.observer.disconnect()
  }

  fit() {
    this.setZoom(this.scrollTarget.clientWidth / this.pageWidth(), { keepCenter: false })
  }

  zoomIn() {
    this.setZoom(this.zoom() + 0.05)
  }

  zoomOut() {
    this.setZoom(this.zoom() - 0.05)
  }

  slide() {
    this.setZoom(this.zoomTarget.value / 100)
  }

  type() {
    this.setZoom(this.zoomValueTarget.value / 100)
  }

  jump(event) {
    const page = this.pageTargets[Number(event.currentTarget.dataset.page) - 1]
    if (page) this.scrollTarget.scrollTop = page.offsetTop - this.pageTargets[0].offsetTop
  }

  hide() {
    this.paneTarget.hidden = true
    this.hiddenTarget.hidden = false
    this.stick()
  }

  show() {
    this.hiddenTarget.hidden = true
    this.paneTarget.hidden = false
    this.stick()
  }

  setZoom(next, { keepCenter = true } = {}) {
    const zoom = Math.min(2.5, Math.max(0.25, next))
    const centerRatio = keepCenter ? this.centerRatio() : 0.5
    this.pageTargets.forEach((page) => { page.style.width = `${Math.round(this.pageWidth() * zoom)}px` })

    const percent = Math.round(zoom * 100)
    this.zoomTarget.value = percent
    this.zoomValueTarget.value = percent
    this.scrollTarget.scrollLeft = centerRatio * this.scrollTarget.scrollWidth - this.scrollTarget.clientWidth / 2
  }

  zoom() {
    return Number(this.zoomValueTarget.value) / 100
  }

  // ページの実寸。受け取れていなければ、等倍として扱う。
  pageWidth() {
    return this.pageWidthValue || this.scrollTarget.clientWidth
  }

  centerRatio() {
    const { scrollLeft, clientWidth, scrollWidth } = this.scrollTarget
    return (scrollLeft + clientWidth / 2) / scrollWidth
  }

  // 見出しの行は、上に出ているペイン(または「PDFを表示する」の行)の高さぶん下げて貼り付ける。
  stick() {
    const above = this.paneTarget.hidden ? this.hiddenTarget : this.paneTarget
    this.headRowTarget.style.position = "sticky"
    this.headRowTarget.style.top = `${above.getBoundingClientRect().height}px`
    this.headRowTarget.style.zIndex = "9"
  }
}
