# frozen_string_literal: true

require 'test_helper'

class StudentTest < ActiveSupport::TestCase
  setup do
    @department = Faculty.create!(name: '学生テスト学部').departments.create!(name: '学生テスト学科')
    @published = curricula(:intelligent_informatics)
  end

  test '便覧は無くてもよい' do
    assert build_student.valid?
  end

  test '公開済みの便覧を紐付けられる' do
    student = build_student(curriculum: @published)

    assert_predicate student, :valid?
    assert_equal @published, student.curriculum
  end

  test '下書きの便覧は紐付けられない。判定に使われてはならない' do
    draft = Curriculum.create!(slug: 'intelligent_informatics', admission_year: 2024, document: {})
    student = build_student(curriculum: draft)

    assert_not student.valid?
    assert_includes student.errors.attribute_names, :curriculum
  end

  private

  def build_student(**attributes)
    Student.new(user: User.create!(email: "student-#{SecureRandom.hex(4)}@example.test"),
                department: @department, admission_year: 2024, **attributes)
  end
end

