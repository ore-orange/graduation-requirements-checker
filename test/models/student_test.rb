# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class StudentTest < ActiveSupport::TestCase
  setup do
    faculty = Faculty.create!(name: 'テスト学部')
    @department = Department.create!(faculty: faculty, name: 'テスト学科')
    user = User.create!(email: 'student@example.test', password: 'a-test-password')
    @student = Student.create!(user: user, department: @department, admission_year: 2024)
  end

  test '学科に紐づくカリキュラムを読む' do
    @department.update!(curriculum_slug: 'intelligent_informatics')

    assert_equal 'intelligent_informatics', @student.curriculum_slug
    assert_kind_of Array, @student.curriculum.fetch('courses')
  end

  test 'カリキュラムが未設定なら初期設定を促す' do
    assert_raises(SetupIncomplete) { @student.curriculum }
  end

  test '指し先のカリキュラムが無いときも初期設定を促す' do
    @department.update!(curriculum_slug: 'unregistered_test_department')

    assert_raises(SetupIncomplete) { @student.curriculum }
  end

  test 'カリキュラムが壊れている場合は初期設定として扱わない' do
    @department.update!(curriculum_slug: 'intelligent_informatics')
    broken = proc { raise CurriculumRepository::InvalidDocument, 'broken' }

    CurriculumRepository.stub(:find, broken) do
      assert_raises(CurriculumRepository::InvalidDocument) { @student.curriculum }
    end
  end
end

