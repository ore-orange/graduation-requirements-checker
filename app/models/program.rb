# frozen_string_literal: true

class Program < ApplicationRecord
  belongs_to :department
  has_many :student_program_assignments, dependent: :restrict_with_error
  has_many :students, through: :student_program_assignments

  validates :name, presence: true
end

