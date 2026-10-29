# frozen_string_literal: true

require 'json'

# 学部・コースごとの卒業要件の便覧。公開済み（published_at あり）が学生の判定に使われる。
# 取り込み途中の下書きも同じ表に置くので、同じ slug・年度の下書きは何件でも作れる。
class Curriculum < ApplicationRecord
  SLUG_FORMAT = /\A[a-z][a-z0-9_]*\z/

  validates :slug, presence: true, format: { with: SLUG_FORMAT }
  validates :admission_year, numericality: { only_integer: true, in: 1..9999 }

  scope :published, -> { where.not(published_at: nil) }

  # 便覧のJSONを公開済みとして入れる。slug はディレクトリ名、入学年度はファイル名から決める。
  # 同じ slug・年度の公開済みがあれば更新するので、何度流しても増えない。下書きには触れない。
  def self.seed_from_file(path)
    path = Pathname.new(path)
    slug = path.dirname.basename.to_s
    admission_year = Integer(path.basename('.json').to_s, 10)
    document = JSON.parse(path.read)

    curriculum = published.find_or_initialize_by(slug: slug, admission_year: admission_year)
    curriculum.update!(document: document, title: document['title'], source_filename: path.basename.to_s,
                       published_at: curriculum.published_at || Time.current)
    curriculum
  end

  def published?
    published_at.present?
  end

  # 便覧の規則。壊れた便覧は Catalogue が ArgumentError にするので、ここでは握りつぶさない。
  def catalogue
    GraduationAssessment::Catalogue.new(document)
  end
end

