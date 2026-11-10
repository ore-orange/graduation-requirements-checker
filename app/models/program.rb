# frozen_string_literal: true

class Program < ApplicationRecord
  belongs_to :department
  has_many :students, dependent: :restrict_with_error
  # コース変更の履歴を持たせるための表。いまは未使用。
  has_many :student_program_assignments, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: { scope: :department_id }
end

