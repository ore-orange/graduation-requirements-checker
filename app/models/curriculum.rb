# frozen_string_literal: true

# 学部・学科・コースごとの便覧(卒業要件の文書)。中身は document に、config/curricula のJSONと同じ形で持つ。
# 学生の判定に使うのは公開済み(published_at あり)だけ。
class Curriculum < ApplicationRecord
  SLUG_FORMAT = /\A[a-z][a-z0-9_]*\z/

  scope :published, -> { where.not(published_at: nil) }
  scope :drafts, -> { where(published_at: nil) }

  # 読み取りの状態(pages[n]['status'])の呼び方。pending は取り込み直後で、まだ読んでいない。
  PAGE_STATUS_LABELS = { 'pending' => '未読', 'read' => '読み取り済み', 'failed' => '読み取りに失敗' }.freeze

  # 下書きを消すときに、取り込んだページ画像もここごと消す。
  after_destroy { FileUtils.rm_rf(images_dir) }

  class << self
    # ページ画像の置き場の根。環境ごとに分ける(テストが開発用の画像を消さないように)。
    # テストでは、並列の実行ごとに別の場所を割り当てる。画像は <images_root>/<id>/p<ページ番号>.png に置く。
    attr_writer :images_root

    def images_root
      @images_root ||= Rails.root.join('storage/curricula', Rails.env)
    end
  end

  validates :slug, presence: true, format: { with: SLUG_FORMAT }
  validates :admission_year, numericality: { only_integer: true, in: 1..9999 }
  validate :document_must_be_object

  # コースの slug と入学年度に当たる公開済みの便覧。無ければ nil。
  def self.find_published(slug:, admission_year:)
    published.find_by(slug: slug, admission_year: admission_year)
  end

  # 公開済みの便覧がある入学年度(古い順)。
  def self.published_years(slug)
    published.where(slug: slug).order(:admission_year).pluck(:admission_year)
  end

  def published?
    published_at.present?
  end

  def images_dir
    self.class.images_root.join(id.to_s)
  end

  # ページ番号(1始まり)の画像。無ければ nil。パスは id とページ番号だけから作り、リクエストの文字列を混ぜない。
  def page_image_path(page)
    number = Integer(page.to_s, 10, exception: false)
    return unless number&.positive?

    path = images_dir.join("p#{number}.png")
    path if path.file?
  end

  def page_entry(page)
    pages.find { |entry| entry['page'] == page }
  end

  private

  # jsonb には配列や文字列も入るが、判定は便覧をオブジェクトとして読む。
  def document_must_be_object
    errors.add(:document, 'はJSONのオブジェクトにしてください') unless document.is_a?(Hash)
  end
end

