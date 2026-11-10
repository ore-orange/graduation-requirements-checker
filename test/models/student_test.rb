# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class StudentTest < ActiveSupport::TestCase
  setup do
    faculty = Faculty.create!(name: 'テスト学部')
    department = Department.create!(faculty: faculty, name: 'テスト学科')
    @program = Program.create!(department: department, name: 'テストコース')
    user = User.create!(email: 'student@example.test', password: 'a-test-password')
    @student = Student.create!(user: user, program: @program, admission_year: 2024)
  end

  test 'コースに紐づくカリキュラムを読む' do
    @program.update!(curriculum_slug: 'intelligent_informatics')

    assert_equal 'intelligent_informatics', @student.curriculum_slug
    assert_kind_of Array, @student.curriculum.fetch('courses')
  end

  test 'カリキュラムが未設定なら初期設定を促す' do
    assert_raises(SetupIncomplete) { @student.curriculum }
  end

  test '指し先のカリキュラムが無いときも初期設定を促す' do
    @program.update!(curriculum_slug: 'unregistered_test_curriculum')

    assert_raises(SetupIncomplete) { @student.curriculum }
  end

  test '用意していない入学年度では学生を作れない' do
    @program.update!(curriculum_slug: 'intelligent_informatics')
    user = User.create!(email: 'another@example.test', password: 'a-test-password')
    student = Student.new(user: user, program: @program, admission_year: 2030)

    assert_not student.valid?
    assert student.errors.of_kind?(:admission_year, :no_curriculum)
  end

  test '作成済みの学生は入学年度のカリキュラムが消えても保存できる' do
    @program.update!(curriculum_slug: 'intelligent_informatics')
    @student.admission_year = 2030

    # 検証を作成時だけにしているため、後からJSONを入れ替えても既存の学生を保存できる
    assert_predicate @student, :valid?
  end

  test 'カリキュラムが壊れている場合は初期設定として扱わない' do
    @program.update!(curriculum_slug: 'intelligent_informatics')
    broken = proc { raise CurriculumRepository::InvalidDocument, 'broken' }

    CurriculumRepository.stub(:find, broken) do
      assert_raises(CurriculumRepository::InvalidDocument) { @student.curriculum }
    end
  end
end

