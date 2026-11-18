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
  # 学部名・コース名は人が選ぶ・打つ値なので、前後の空白や全角空白の揺れで「別の課程」にならないよう揃える。
  # 識別名を引き継ぐ照合(slug_for_program)も同じ形で比べる(where にも効く)。
  normalizes :faculty_name, :department_name, with: ->(name) { name.squish }

  # 下書きを消すときに、取り出したページ画像もここごと消す。
  after_destroy { FileUtils.rm_rf(images_dir) }

  scope :published, -> { where.not(published_at: nil) }
  scope :drafts, -> { where(published_at: nil) }
  # 一覧に要る列だけ。document は大きいので読まない。
  scope :for_listing, -> {
    select(:id, :slug, :admission_year, :faculty_name, :department_name, :title,
           :source_filename, :pages, :import_error, :published_at, :updated_at)
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

  def images_dir
    self.class.images_root.join(id.to_s)
  end

  def published?
    published_at.present?
  end

  # 便覧の規則。壊れた便覧は Catalogue が ArgumentError にするので、ここでは握りつぶさない。
  def catalogue
    GraduationAssessment::Catalogue.new(document)
  end
end

