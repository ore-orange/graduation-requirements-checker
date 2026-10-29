# frozen_string_literal: true

class StudentCourse < ApplicationRecord
  ENROLLMENT_STATUSES = %w[completed registered in_progress failed unknown].freeze

  belongs_to :student
  belongs_to :course

  validates :academic_year, numericality: { only_integer: true, greater_than: 0, less_than: 10_000 }
  validates :enrollment_status, inclusion: { in: ENROLLMENT_STATUSES }
  validates :credits_earned, numericality: { greater_than_or_equal_to: 0, less_than: 1000 }, allow_nil: true

  # 判定に渡す履修の記録。key は Course の科目番号であって、便覧の科目の key ではない。
  # GraduationAssessment へ渡す前に StudentWorkspace#catalogue_entries を通すこと。直接渡すと、どの科目も
  # 便覧の科目表に当たらず、すべて要確認になる。
  def assessment_entry
    credits = case enrollment_status
              when 'completed' then credits_earned
              when 'registered', 'in_progress' then course.credits
              end

    { key: course.course_number, credits: credits, approved: approval_confirmed, name: course.name }
  end
end

