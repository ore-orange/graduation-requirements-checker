# frozen_string_literal: true

# 授業時間配当表の1行（科目・学期ごとの開講情報）。科目そのものはCourseが持つ。
class CourseOffering < ApplicationRecord
  SEMESTERS = TimetableImport::Values::SEMESTERS
  REQUIREMENT_TYPES = TimetableImport::Values::REQUIREMENT_TYPES
  WEEKDAYS = TimetableImport::Values::WEEKDAYS

  belongs_to :course

  validates :semester, inclusion: { in: SEMESTERS }
  validates :requirement_type, inclusion: { in: REQUIREMENT_TYPES }, allow_nil: true
  validates :weekday, inclusion: { in: WEEKDAYS }, allow_nil: true
  validates :lecture_code, uniqueness: { scope: :semester }, allow_nil: true
end

