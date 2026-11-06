# frozen_string_literal: true

class Program < ApplicationRecord
  belongs_to :department
  has_many :student_program_assignments, dependent: :restrict_with_error
  has_many :students, through: :student_program_assignments

  validates :name, presence: true

  # Curriculum#department_name は学科名とコース名を1つの文字列で持つ(例: "工学科 知能情報コース"。スキーマは分けない)。
  # 画面やリダイレクトでは学科・コースを別のプルダウンで扱うので、結合済みの文字列から引き当てて分ける。
  # 当たらなければ(コースの無い学科、または未知のコース)、文字列全体を学科名としてそのまま返す。
  def self.department_and_course_for(combined_name)
    return [combined_name, nil] if combined_name.blank?

    match = includes(:department).find { |program| "#{program.department.name} #{program.name}" == combined_name }
    match ? [match.department.name, match.name] : [combined_name, nil]
  end
end

