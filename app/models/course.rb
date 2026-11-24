# frozen_string_literal: true

# 科目1件。便覧(カリキュラムJSON)由来の科目と、授業時間配当表の開講1件が同じ表に入る。
# 便覧由来の行は curriculum_key を持ち、開講の列(年度・学期・講義コードなど)は空。
# 開講1件の行は curriculum_key を持たず、(年度, 学期, 講義コード)で一意。
# 履修履歴・履修計画が参照するのは、curriculum_key を持つ行だけ。
class Course < ApplicationRecord
  SEMESTERS = TimetableImport::Values::SEMESTERS
  REQUIREMENT_TYPES = TimetableImport::Values::REQUIREMENT_TYPES
  WEEKDAYS = TimetableImport::Values::WEEKDAYS

  has_many :student_courses, dependent: :restrict_with_error
  has_many :students, through: :student_courses
  has_many :planned_courses, dependent: :restrict_with_error
  # 年度・学科は、便覧由来の科目(年度も学科も持たない)が同じ表に入るため空を許す。
  # 取り込みの画面では必須なので、PDFから入った講義に空はできない。
  belongs_to :department, optional: true

  # 授業時間配当表から入った開講1件の行
  scope :offered, -> { where.not(lecture_code: nil) }

  validates :name, presence: true
  validates :curriculum_key, uniqueness: true, allow_nil: true
  validates :credits, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 1000 },
                      allow_nil: true
  validates :semester, inclusion: { in: SEMESTERS }, allow_nil: true
  # 開講1件の行は講義コードと学期を両方持ち、便覧由来の行はどちらも持たない。
  # DBの courses_offering_pair と同じことを、保存前に検証でも見る。
  validates :semester, presence: true, if: -> { lecture_code.present? }
  validates :lecture_code, presence: true, if: -> { semester.present? }
  validates :lecture_code, uniqueness: { scope: %i[year semester] }, allow_nil: true
  validates :requirement_type, inclusion: { in: REQUIREMENT_TYPES }, allow_nil: true
  validates :weekday, inclusion: { in: WEEKDAYS }, allow_nil: true
  validates :year, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 9999 },
                   allow_nil: true
end

