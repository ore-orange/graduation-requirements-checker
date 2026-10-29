# frozen_string_literal: true

class Course < ApplicationRecord
  has_many :student_courses, dependent: :restrict_with_error
  has_many :students, through: :student_courses
  has_many :planned_courses, dependent: :restrict_with_error
  has_many :course_offerings, dependent: :restrict_with_error

  validates :name, presence: true
  validates :credits, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 1000 },
                      allow_nil: true

  # 学生が計画に自由入力した科目。便覧の科目表に無いので、区分は入力のときに決めた custom_category が持つ。
  def custom? = custom_category.present?
end

