# frozen_string_literal: true

# 授業時間配当表の1行（科目・学期ごとの開講情報）。科目そのものはCourseが持つ。
class CourseOffering < ApplicationRecord
  SEMESTERS = TimetableImport::Values::SEMESTERS
  REQUIREMENT_TYPES = TimetableImport::Values::REQUIREMENT_TYPES
  WEEKDAYS = TimetableImport::Values::WEEKDAYS

  belongs_to :course
  # 年度・学科は、#53 で courses と統合したあとに残る curriculum_key 由来の科目のために空を許す。
  # 取り込みの画面では必須なので、PDFから入った講義に空はできない。
  belongs_to :department, optional: true

  validates :semester, inclusion: { in: SEMESTERS }
  validates :requirement_type, inclusion: { in: REQUIREMENT_TYPES }, allow_nil: true
  validates :weekday, inclusion: { in: WEEKDAYS }, allow_nil: true
  validates :lecture_code, presence: true, uniqueness: { scope: %i[year semester] }
  validates :year, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 9999 },
                   allow_nil: true
end

