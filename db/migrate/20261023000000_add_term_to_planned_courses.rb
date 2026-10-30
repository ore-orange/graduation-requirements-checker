# frozen_string_literal: true

# 将来計画科目に履修予定の年度・学期を持たせる。
# 既存の予定と、学期を選ばずに追加された予定は「学期未定」として両方 NULL のまま残す。
class AddTermToPlannedCourses < ActiveRecord::Migration[8.1]
  def change
    add_column :planned_courses, :academic_year, :integer
    add_column :planned_courses, :semester, :string
    add_check_constraint :planned_courses, 'academic_year BETWEEN 1 AND 9999',
                         name: 'planned_courses_year_range'
    add_check_constraint :planned_courses, "semester IN ('前期', '後期')",
                         name: 'planned_courses_semester'
    add_check_constraint :planned_courses, '(academic_year IS NULL) = (semester IS NULL)',
                         name: 'planned_courses_term_pair'
  end
end
