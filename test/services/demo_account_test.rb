# frozen_string_literal: true

require 'test_helper'

# DemoAccount.student（単数）の「常に1人目(2024年度)を返す」契約と、
# 年度で引く student_for_year の振る舞いを確かめる。
class DemoAccountTest < ActiveSupport::TestCase
  setup { DemoData.load! }

  # 「並びを入れ替えても」ではなく、実装どおり「常に STUDENTS.first (2024年度)を返す」という契約の確認。
  test 'student は常に STUDENTS.first (2024年度)を返す契約' do
    assert_equal 2024, DemoAccount.student.admission_year
  end

  test 'student_for_year は STUDENTS に無い年度なら student にそのまま落ちる' do
    assert_equal DemoAccount.student, DemoAccount.student_for_year(1999)
  end

  test 'student_for_year は一致する年度のデモ学生を返す' do
    assert_equal 2025, DemoAccount.student_for_year(2025).admission_year
  end

  test 'available_students は実際にDBへ投入済みのデモ学生だけを返す' do
    assert_equal [2024, 2025], DemoAccount.available_students.map(&:admission_year).sort
  end
end

