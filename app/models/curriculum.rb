# frozen_string_literal: true

# 学部・学科・コースごとの便覧(卒業要件の文書)。中身は document に、config/curricula のJSONと同じ形で持つ。
# 学生の判定に使うのは公開済み(published_at あり)だけ。
class Curriculum < ApplicationRecord
  SLUG_FORMAT = /\A[a-z][a-z0-9_]*\z/

  scope :published, -> { where.not(published_at: nil) }

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

  private

  # jsonb には配列や文字列も入るが、判定は便覧をオブジェクトとして読む。
  def document_must_be_object
    errors.add(:document, 'はJSONのオブジェクトにしてください') unless document.is_a?(Hash)
  end
end

