# frozen_string_literal: true

class Student < ApplicationRecord
  belongs_to :user
  belongs_to :department
  # 判定に使う便覧。入学年度と学科で決まるが、探すのではなく学生が持つ。
  belongs_to :curriculum, optional: true
  has_many :student_courses, dependent: :restrict_with_error
  has_many :courses, through: :student_courses
  has_many :planned_courses, dependent: :destroy
  has_many :future_courses, through: :planned_courses, source: :course
  has_many :student_program_assignments, dependent: :restrict_with_error
  has_many :programs, through: :student_program_assignments

  validates :user_id, uniqueness: true
  validates :admission_year, numericality: { only_integer: true, greater_than: 0, less_than: 10_000 }
  validate :curriculum_must_be_published, if: :will_save_change_to_curriculum_id?

  private

  # 下書きは取り込み途中の作業中の文書。学生の判定に使われてはならない。
  def curriculum_must_be_published
    errors.add(:curriculum, 'は公開済みのものにしてください') if curriculum && !curriculum.published?
  end
end

