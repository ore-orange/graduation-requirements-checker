# frozen_string_literal: true

class PlannedCourse < ApplicationRecord
  SEMESTERS = %w[前期 後期].freeze

  belongs_to :student
  belongs_to :course

  validates :course_id, uniqueness: { scope: :student_id }
  # 年度・学期は両方そろえて入れるか、両方空（学期未定）にする。
  validates :academic_year, numericality: { only_integer: true, greater_than: 0, less_than: 10_000 }, allow_nil: true
  validates :semester, inclusion: { in: SEMESTERS }, allow_nil: true
  validates :academic_year, presence: true, if: :semester
  validates :semester, presence: true, if: :academic_year
end

