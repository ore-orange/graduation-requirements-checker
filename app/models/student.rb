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

  validates :user_id, uniqueness: true
  validates :admission_year, numericality: { only_integer: true, greater_than: 0, less_than: 10_000 }
end

