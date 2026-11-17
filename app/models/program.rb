# frozen_string_literal: true

class Program < ApplicationRecord
  belongs_to :department
  has_many :students, dependent: :restrict_with_error
  # コース変更の履歴を持たせるための表。いまは未使用。
  has_many :student_program_assignments, dependent: :restrict_with_error

  # カリキュラムを用意していないコースは、選ばれても画面が出せないので選択肢に出さない。
  scope :selectable, -> { where.not(curriculum_slug: nil).includes(department: :faculty).order(:id) }

  # 選択肢に出す名前。同名のコースが別の学科にもあり得るので、学部と学科まで含める。
  def full_name
    "#{department.faculty.name} #{department.name} #{name}"
  end

  validates :name, presence: true, uniqueness: { scope: :department_id }
end

