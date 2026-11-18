# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class SampleStudentTest < ActiveSupport::TestCase
  test 'loading repeatedly preserves plans unrelated data and non-seeded history' do
    student = SampleStudent.load!
    course = student.student_courses.first.course
    plan = student.planned_courses.create!(course: course, academic_year: 2026, semester: '後期')
    history = student.student_courses.create!(course: course, academic_year: 2023, semester: 'manual-test',
                                              grade: 'manual-result', enrollment_status: 'unknown',
                                              credits_earned: '1.5', approval_confirmed: false)
    unrelated_user = User.create!(email: 'unrelated@example.test', password: 'a-test-password')
    unrelated_course = Course.create!(course_number: course.course_number, name: course.name, credits: 9)
    unrelated_student = Student.create!(user: unrelated_user, program: student.program, admission_year: 2024)
    unrelated_plan = unrelated_student.planned_courses.create!(course: unrelated_course,
                                                               academic_year: 2026, semester: '後期')
    before_counts = record_counts
    before_history = history.attributes
    before_course = unrelated_course.attributes

    2.times { assert_equal student, SampleStudent.load! }

    assert_equal before_counts, record_counts
    assert_equal plan, student.planned_courses.find(plan.id)
    assert_equal unrelated_plan, unrelated_student.planned_courses.find(unrelated_plan.id)
    assert_equal before_history, history.reload.attributes
    assert_equal before_course, unrelated_course.reload.attributes
    assert_equal unrelated_user, User.find(unrelated_user.id)
  end

  test '種ファイルの単位は、すでにある科目の値を上書きしない' do
    # 単位は先着優先。あとから読む行で無条件に上書きすると、「未確認」にしている値が黙って復活する。
    entry = course_master.first
    existing = Course.create!(course_number: entry.fetch('number'), name: entry.fetch('name'), credits: 99)

    SampleStudent.load!

    assert_equal 99, existing.reload.credits
  end

  test '同じ番号で名前の違う科目があっても、履修は同じ行につながる' do
    entry = course_master.find { |course| sample_numbers.include?(course.fetch('number')) }
    Course.create!(course_number: entry.fetch('number'), name: "#{entry.fetch('name')}（別名）")

    student = SampleStudent.load!
    before = student.student_courses.count
    SampleStudent.load!

    assert_equal before, student.student_courses.count
  end

  test 'conflicting existing cohort is not overwritten and loading is atomic' do
    faculty = Faculty.create!(name: '既存学部')
    department = faculty.departments.create!(name: '既存学科')
    program = department.programs.create!(name: '既存コース', curriculum_slug: 'intelligent_informatics')
    user = User.create!(email: SampleStudent::EMAIL, password: 'a-test-password')
    student = user.create_student!(program: program, admission_year: 2025)
    before = record_counts

    assert_raises(SampleStudent::Conflict) { SampleStudent.load! }

    assert_equal before, record_counts
    assert_equal 2025, student.reload.admission_year
    assert_equal program, student.program
    assert_equal department, student.department
  end

  private

  def course_master
    JSON.parse(Rails.root.join(SampleStudent::COURSE_MASTER_PATH).read)
  end

  def sample_numbers
    JSON.parse(Rails.root.join(SampleStudent::ENROLLMENTS_PATH).read)
        .fetch('enrollments').map { |entry| entry.fetch('course_number') }
  end

  def record_counts
    [User, Faculty, Department, Student, Course, StudentCourse, PlannedCourse].to_h do |model|
      [model.name, model.count]
    end
  end
end

