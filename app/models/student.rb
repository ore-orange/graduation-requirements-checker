# frozen_string_literal: true

class Student < ApplicationRecord
  belongs_to :user
  belongs_to :program
  has_many :student_courses, dependent: :restrict_with_error
  has_many :courses, through: :student_courses
  has_many :planned_courses, dependent: :destroy
  has_many :future_courses, through: :planned_courses, source: :course
  has_many :student_program_assignments, dependent: :restrict_with_error

  # 卒業要件はコース単位で分かれる。学科はコースを通して引く。
  delegate :curriculum_slug, :department, to: :program

  validates :user_id, uniqueness: true
  validates :admission_year, numericality: { only_integer: true, greater_than: 0, less_than: 10_000 }
  # 入れた瞬間に画面が出せない学生を作らないよう、入学年度のカリキュラムがあることを確かめる。
  # 作成時だけにするのは、後からカリキュラムのJSONを入れ替えても既存の学生を保存できなくしないため。
  validate :curriculum_must_exist, on: :create

  # この学生に適用される卒業要件。JSONが壊れている場合は握りつぶさず、そのまま落とす。
  def curriculum
    raise SetupIncomplete, 'コースにカリキュラムが登録されていません。' if curriculum_slug.blank?

    CurriculumRepository.find(curriculum: curriculum_slug, admission_year: admission_year)
  rescue CurriculumRepository::NotFound
    raise SetupIncomplete, "#{admission_year}年度のカリキュラムが登録されていません。"
  end

  private

  # カリキュラムを用意していないコースは、まだ年度を絞れないので素通しする。
  def curriculum_must_exist
    return if program.blank? || curriculum_slug.blank? || admission_year.blank?
    return unless admission_year.is_a?(Integer)
    return if CurriculumRepository.available_years(curriculum: curriculum_slug).include?(admission_year)

    errors.add(:admission_year, :no_curriculum)
  end
end

