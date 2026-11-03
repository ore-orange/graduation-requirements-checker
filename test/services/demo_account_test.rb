# frozen_string_literal: true

require 'test_helper'

# DemoAccount.student（単数）の「常に1人目(2024年度)を返す」契約を確かめる。
# 2025年度のデモ学生は DemoData.load! が投入し続けるが、画面からは選べない。
class DemoAccountTest < ActiveSupport::TestCase
  setup { DemoData.load! }

  # 「並びを入れ替えても」ではなく、実装どおり「常に STUDENTS.first (2024年度)を返す」という契約の確認。
  test 'student は常に STUDENTS.first (2024年度)を返す契約' do
    assert_equal 2024, DemoAccount.student.admission_year
  end

  test '切り替えの口は無くなっている' do
    assert_not DemoAccount.respond_to?(:student_for_year)
    assert_not DemoAccount.respond_to?(:available_students)
  end
end

