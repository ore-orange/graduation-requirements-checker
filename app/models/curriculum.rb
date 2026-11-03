# frozen_string_literal: true

require 'json'

# 学部・コースごとの卒業要件の便覧。公開済み（published_at あり）が学生の判定に使われる。
# 取り込み途中の下書きも同じ表に置くので、同じ slug・年度の下書きは何件でも作れる。
class Curriculum < ApplicationRecord
  SLUG_FORMAT = /\A[a-z][a-z0-9_]*\z/

  # 学生が指している便覧は消せない(判定に使われている)。外部キーが先に落ちて500にならないよう、モデルで断る。
  has_many :students, dependent: :restrict_with_error

  validates :slug, presence: true, format: { with: SLUG_FORMAT }
  validates :admission_year, numericality: { only_integer: true, in: 1..9999 }
  # 画面から上げる下書きは、学部とコースも必須。年度のない・学部のない下書きは便覧にならない。
  # 種まきや既存の行は学部名を持たないので、save(context: :upload) のときだけ求める。
  validates :faculty_name, :department_name, presence: true, on: :upload
  # 入学年度は現実的な範囲に絞る(5年度のような下書きを作らせない)。アップロードの入力欄の min・max と同じ範囲。
  validates :admission_year, inclusion: { in: ->(_) { Curriculum.upload_year_range } }, on: :upload

  # 読むページの種別。取り込み直後はすべて skip で、どのページを読むかは人が決める。
  PAGE_KINDS = %w[skip courses requirements].freeze
  PAGE_KIND_LABELS = { 'courses' => '科目表', 'requirements' => '要件表', 'skip' => '読まない' }.freeze
  # AIに読ませるページの種別(skip は読まない)。
  READABLE_PAGE_KINDS = %w[requirements courses].freeze
  # pages[n]['status'] の画面での呼び方。pending は取り込み直後で、まだ読んでいない。
  PAGE_STATUS_LABELS = { 'pending' => '未読', 'read' => '読み取り済み', 'failed' => '読み取りに失敗' }.freeze
  # 1つのPDFとして現実的な上限。手でページ数を指定するときに、桁違いの値で表を膨らませないため。
  MAX_PAGES = 500

  # 下書きを消すときに、取り出したページ画像もここごと消す。
  after_destroy { FileUtils.rm_rf(images_dir) }

  scope :published, -> { where.not(published_at: nil) }
  scope :drafts, -> { where(published_at: nil) }
  # 一覧に要る列だけ。document は大きいので読まない。
  scope :for_listing, -> {
    select(:id, :slug, :admission_year, :faculty_name, :department_name, :title,
           :source_filename, :pages, :import_error, :published_at)
  }

  class << self
    # ページ画像の置き場の根。環境ごとに分ける(テストが開発用の画像を消さないように)。
    # テストでは、並列の実行ごとに別の場所を割り当てる。画像は <images_root>/<id>/p<n>.png に置く。
    attr_writer :images_root

    def images_root
      @images_root ||= Rails.root.join('storage/curricula', Rails.env)
    end
  end

  # 便覧のJSONを公開済みとして入れる。slug はディレクトリ名、入学年度はファイル名から決める。下書きには触れない。
  # 同じ slug・年度の公開済みが無ければ作る。ある場合は overwrite のときだけファイルの内容で更新する。
  # 開発・テストではファイルを直すたびに流し直せるよう更新する。本番では、公開済みになった時点でDBが正本なので、
  # 画面から公開した便覧をファイルの古い内容に戻さないよう、既存の行には触れない（ファイルは初回の種にすぎない）。
  def self.seed_from_file(path, overwrite: Rails.env.local?)
    path = Pathname.new(path)
    slug = path.dirname.basename.to_s
    admission_year = admission_year_of(path)

    curriculum = published.find_or_initialize_by(slug: slug, admission_year: admission_year)
    return curriculum if curriculum.persisted? && !overwrite

    document = parse_document(path)
    # 学部名・学科コース名は、文書が持つ値を列へ写す(プルダウンの選択肢はこの列から作る)。文書の department は slug で
    # 別物なので読まない。文書に無いファイルは、列を nil で上書きして消さない。
    names = document.slice('faculty_name', 'department_name').compact_blank.symbolize_keys
    curriculum.update!(document: document, title: document['title'], source_filename: path.basename.to_s,
                       published_at: curriculum.published_at || Time.current, **names)
    curriculum
  end

  # どのファイルが悪いか分かるように、例外にはパスを入れる。seeds.rb は **/*.json を全部読むため。
  def self.admission_year_of(path)
    Integer(path.basename('.json').to_s, 10)
  rescue ArgumentError
    raise ArgumentError, "便覧のファイル名は入学年度（例: 2024.json）にしてください: #{path}"
  end

  def self.parse_document(path)
    JSON.parse(path.read)
  rescue JSON::ParserError
    # パーサーのメッセージには本文が含まれ得るので、パスだけを出す。
    raise ArgumentError, "便覧のJSONを読めません: #{path}"
  end
  private_class_method :admission_year_of, :parse_document

  UPLOAD_MIN_YEAR = 2000

  # 画面から上げる下書きの入学年度の範囲。上限は、来年度・再来年度入学の便覧を先に作れるよう今年+2。
  def self.upload_year_range
    UPLOAD_MIN_YEAR..(Time.zone.today.year + 2)
  end

  # 取り込み直後のページ一覧。text はアップロードのときに PDF から取り出したそのページの文字(取り出せなければ nil か空)。
  # PDFは残らないので、あとから取り直せない。
  def self.blank_pages(count, texts: [])
    Array.new(count) do |index|
      { 'page' => index + 1, 'kind' => 'skip', 'status' => 'pending', 'error' => nil, 'text' => texts[index] }
    end
  end

  def images_dir
    self.class.images_root.join(id.to_s)
  end

  # 画面に出すページ画像。1始まりのページ番号で引く。無ければ nil。
  # パスはこの下書きの id とページ番号からだけ組み立て、リクエストの文字列は混ぜない。
  def page_image_path(page)
    return unless page.to_s.match?(/\A[1-9]\d{0,3}\z/)

    path = images_dir.join("p#{page.to_i}.png")
    path if path.file?
  end

  # ページ画像の実寸(横幅px)。PDFペインの倍率は、これをもとに決める。無ければ nil。
  def page_image_width(page)
    path = page_image_path(page)
    TimetableImport::PageImages.width(path) if path
  end

  # ページ画像の中身。無ければ nil。
  def page_image_data(page)
    path = page_image_path(page)
    path&.binread
  end

  def published?
    published_at.present?
  end

  # 公開できるか、できないなら理由(人が直せる文)。決めるのは CurriculumImport::Publication の1か所。
  # replace は、同じ識別名・入学年度の公開済みを下書きに戻して差し替える(学生の判定が切り替わる)と明示したとき。
  def publishable?(replace: false) = blocking_reasons(replace: replace).empty?

  def blocking_reasons(replace: false) = CurriculumImport::Publication.new(self, replace: replace).blocking_reasons

  # 公開する。確認用の欄・ページの記録・ページ画像を落とし、公開済みにする。できなければ Publication::Refused。
  # acknowledged は、画面が見せた警告の一覧の指紋(Publication#digest)。警告があるときだけ要る。
  def publish!(acknowledged: nil, replace: false)
    CurriculumImport::Publication.publish!(self, acknowledged: acknowledged, replace: replace)
  end

  # kinds は { ページ番号 => 種別 }。知らない種別や、存在しないページが混ざっていないか。
  def page_kinds_assignable?(kinds)
    numbers = pages.map { |page| page['page'].to_s }
    kinds.values.all? { |kind| PAGE_KINDS.include?(kind) } && (kinds.keys.map(&:to_s) - numbers).empty?
  end

  # 送られたページだけ種別を替え、他はそのまま残す。page_kinds_assignable? を満たさないときは ArgumentError。
  # 種別が変わるページは、読み取りの結果を document から外し、未読に戻す。種別を替えると、その行はもう
  # 前の種別の結果を読み直せないので、残すと公開する文書に出所の分からない規則・科目が残る(確認済みの科目だけは残す)。
  def assign_page_kinds(kinds)
    raise ArgumentError, "ページの種別を指定できません: #{kinds.inspect}" unless page_kinds_assignable?(kinds)

    kinds = kinds.transform_keys(&:to_s)
    new_document = document.deep_dup
    self.pages = pages.map do |page|
      kind = kinds[page['page'].to_s]
      next page if kind.nil?

      kind == page['kind'] ? page : reset_page(new_document, page, kind)
    end
    self.document = new_document
  end

  # 便覧の規則。壊れた便覧は Catalogue が ArgumentError にするので、ここでは握りつぶさない。
  def catalogue
    GraduationAssessment::Catalogue.new(document)
  end

  private

  def reset_page(document, page, kind)
    kept = CurriculumImport::DraftMerge.withdraw(document, page['contributed'], page['page'])
    # 残した確認済みの科目と、人が直した規則・章・行は、このページの記録に残す。
    # 手放すと、読み直したときに同じものが二重に入る(総単位の印は、読み取りの結果と一緒に外れる)。
    page.except('warnings').merge('kind' => kind, 'status' => 'pending', 'error' => nil,
                                  'contributed' => kept.presence)
  end
end

