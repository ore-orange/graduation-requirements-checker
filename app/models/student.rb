# frozen_string_literal: true

class Student < ApplicationRecord
  belongs_to :user
  belongs_to :department
  has_many :student_courses, dependent: :restrict_with_error
  has_many :courses, through: :student_courses
  has_many :planned_courses, dependent: :destroy
  has_many :future_courses, through: :planned_courses, source: :course
  has_many :student_program_assignments, dependent: :restrict_with_error
  has_many :programs, through: :student_program_assignments

  # どのカリキュラムを適用するかは、いまは学科が持っている。
  # 実際はコース単位で分かれるため、programs を配線したらこの参照先だけを差し替える。
  delegate :curriculum_slug, to: :department

  validates :user_id, uniqueness: true
  validates :admission_year, numericality: { only_integer: true, greater_than: 0, less_than: 10_000 }

  # この学生に適用される卒業要件。JSONが壊れている場合は握りつぶさず、そのまま落とす。
  def curriculum
    raise SetupIncomplete, '学科にカリキュラムが登録されていません。' if curriculum_slug.blank?

    CurriculumRepository.find(department: curriculum_slug, admission_year: admission_year)
  rescue CurriculumRepository::NotFound
    raise SetupIncomplete, "#{admission_year}年度のカリキュラムが登録されていません。"
  end
end

