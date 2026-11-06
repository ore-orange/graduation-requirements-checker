# frozen_string_literal: true

class PlannedCourse < ApplicationRecord
  SEMESTERS = %w[前期 後期].freeze

  belongs_to :student
  belongs_to :course

  validates :course_id, uniqueness: { scope: :student_id }
  # 予定は必ず履修する年度・学期を持つ。
  validates :academic_year, numericality: { only_integer: true, greater_than: 0, less_than: 10_000 }
  validates :semester, inclusion: { in: SEMESTERS }
end

