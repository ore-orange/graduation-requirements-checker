# frozen_string_literal: true

require 'test_helper'

class StudentTest < ActiveSupport::TestCase
  setup do
    @program = programs(:intelligent_informatics)
    @published = curricula(:intelligent_informatics)
  end

  test 'コースの識別名と入学年度から、公開済みの便覧を引き当てる' do
    student = build_student

    assert_predicate student, :valid?
    assert_equal 'intelligent_informatics', student.curriculum_slug
    assert_equal @published, student.curriculum
  end

  test '便覧を用意していない入学年度では学生を作れない' do
    student = build_student(admission_year: 2030)

    assert_not student.valid?
    assert student.errors.of_kind?(:admission_year, :no_curriculum)
  end

  test '便覧を用意していないコースは素通しする。年度を絞れないため' do
    # 便覧の識別名を持たないコースは選択肢に出ない(Program.selectable)ので、ここでは年度を見ない。
    @program.update!(curriculum_slug: nil)
    student = build_student

    assert_predicate student, :valid?
    assert_nil student.curriculum
  end

  test '作成済みの学生は、入学年度の便覧が消えても保存できる' do
    student = build_student
    student.save!
    student.admission_year = 2030

    # 検証を作成時だけにしているため、後から便覧を入れ替えても既存の学生を保存できる
    assert_predicate student, :valid?
  end

  test '下書きの便覧は紐付けられない。判定に使われてはならない' do
    draft = Curriculum.create!(slug: 'intelligent_informatics', admission_year: 2024, document: {})
    student = build_student(curriculum: draft)

    assert_not student.valid?
    assert_includes student.errors.attribute_names, :curriculum
  end

  private

  def build_student(**attributes)
    Student.new(user: User.create!(email: "student-#{SecureRandom.hex(4)}@example.test",
                                   password: 'a-test-password'),
                program: @program, admission_year: 2024, **attributes)
  end
end

