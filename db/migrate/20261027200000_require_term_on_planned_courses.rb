# frozen_string_literal: true

# 将来計画科目の年度・学期を必須にする。
# 学期未定のまま残っている予定には、実行した日から見た次の学期を入れる。
# 学生の在学期間（1年前期〜4年後期）の外になる場合は、近いほうの端の学期にする。
# down では必須を外すだけで、埋めた学期は空に戻さない（どれが学期未定だったかは分からないため）。
class RequireTermOnPlannedCourses < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE planned_courses AS plans
      SET academic_year = terms.ordinal / 2,
          semester = CASE terms.ordinal % 2 WHEN 0 THEN '前期' ELSE '後期' END
      FROM (
        SELECT id, LEAST(GREATEST(#{next_term_ordinal}, admission_year * 2), (admission_year * 2) + 7) AS ordinal
        FROM students
      ) AS terms
      WHERE plans.student_id = terms.id AND plans.semester IS NULL
    SQL

    remove_check_constraint :planned_courses, name: 'planned_courses_term_pair'
    change_column_null :planned_courses, :academic_year, false
    change_column_null :planned_courses, :semester, false
  end

  def down
    change_column_null :planned_courses, :semester, true
    change_column_null :planned_courses, :academic_year, true
    add_check_constraint :planned_courses, '(academic_year IS NULL) = (semester IS NULL)',
                         name: 'planned_courses_term_pair'
  end

  private

  # 学期を「年度 × 2 + (前期 0 / 後期 1)」の通し番号で表す。年度は4月始まり、4〜9月が前期。
  def next_term_ordinal(date = Date.current)
    academic_year = date.month >= 4 ? date.year : date.year - 1
    current = (academic_year * 2) + (date.month.between?(4, 9) ? 0 : 1)
    current + 1
  end
end
