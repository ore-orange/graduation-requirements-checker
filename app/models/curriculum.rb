# frozen_string_literal: true

require 'json'

# 学部・コースごとの卒業要件の便覧。公開済み（published_at あり）が学生の判定に使われる。
# 取り込み途中の下書きも同じ表に置くので、同じ slug・年度の下書きは何件でも作れる。
class Curriculum < ApplicationRecord
  SLUG_FORMAT = /\A[a-z][a-z0-9_]*\z/

  validates :slug, presence: true, format: { with: SLUG_FORMAT }
  validates :admission_year, numericality: { only_integer: true, in: 1..9999 }
  # 画面から上げる下書きは、学部とコースも必須。年度のない・学部のない下書きは便覧にならない。
  # 種まきや既存の行は学部名を持たないので、save(context: :upload) のときだけ求める。
  validates :faculty_name, :department_name, presence: true, on: :upload

  # 読むページの種別。取り込み直後はすべて skip で、どのページを読むかは人が決める。
  PAGE_KINDS = %w[skip courses requirements].freeze
  PAGE_KIND_LABELS = { 'courses' => '科目表', 'requirements' => '要件表', 'skip' => '読まない' }.freeze
  # 1つのPDFとして現実的な上限。手でページ数を指定するときに、桁違いの値で表を膨らませないため。
  MAX_PAGES = 500

  scope :published, -> { where.not(published_at: nil) }
  scope :drafts, -> { where(published_at: nil) }
  # 一覧に要る列だけ。document は大きいので読まない。
  scope :for_listing, -> {
    select(:id, :slug, :admission_year, :faculty_name, :department_name, :title,
           :source_filename, :pages, :published_at)
  }

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
    curriculum.update!(document: document, title: document['title'], source_filename: path.basename.to_s,
                       published_at: curriculum.published_at || Time.current)
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

  # 取り込み直後のページ一覧。text は後続の読み取りが埋める。
  def self.blank_pages(count)
    Array.new(count) do |index|
      { 'page' => index + 1, 'kind' => 'skip', 'status' => 'pending', 'error' => nil, 'text' => nil }
    end
  end

  def published?
    published_at.present?
  end

  # kinds は { ページ番号 => 種別 }。知らない種別や、存在しないページが混ざっていないか。
  def page_kinds_assignable?(kinds)
    numbers = pages.map { |page| page['page'].to_s }
    kinds.values.all? { |kind| PAGE_KINDS.include?(kind) } && (kinds.keys.map(&:to_s) - numbers).empty?
  end

  # 送られたページだけ種別を替え、他はそのまま残す。page_kinds_assignable? を満たさないときは ArgumentError。
  def assign_page_kinds(kinds)
    raise ArgumentError, "ページの種別を指定できません: #{kinds.inspect}" unless page_kinds_assignable?(kinds)

    kinds = kinds.transform_keys(&:to_s)
    self.pages = pages.map do |page|
      kinds.key?(page['page'].to_s) ? page.merge('kind' => kinds[page['page'].to_s]) : page
    end
  end

  # 便覧の規則。壊れた便覧は Catalogue が ArgumentError にするので、ここでは握りつぶさない。
  def catalogue
    GraduationAssessment::Catalogue.new(document)
  end
end

