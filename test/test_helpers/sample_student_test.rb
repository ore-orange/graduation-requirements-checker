# frozen_string_literal: true

require 'test_helper'

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

  test 'unverified source credits and numbers stay unknown rather than being fabricated' do
    document = curriculum
    key = sample_enrollments.first.fetch('course_key')
    entry = document.fetch('courses').find { |course| course.fetch('key') == key }
    entry['number'] = nil
    entry['credits'] = nil
    curricula(:intelligent_informatics2024).update!(document: document)
    student = SampleStudent.load!

    course = Course.find_by!(curriculum_key: key)
    assert_nil course.course_number
    assert_nil course.credits
    current = student.student_courses.create!(course: course, academic_year: 2025, enrollment_status: 'registered')
    assert_nil current.assessment_entry.fetch(:credits)
    assert_nil current.assessment_entry.fetch(:approved)
  end

  test 'conflicting existing cohort is not overwritten and loading is atomic' do
    faculty = Faculty.create!(name: '既存学部')
    department = faculty.departments.create!(name: '既存学科')
    program = department.programs.create!(name: '既存コース')
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

  def curriculum
    curricula(:intelligent_informatics2024).document.deep_dup
  end

  def sample_enrollments
    JSON.parse(Rails.root.join(SampleStudent::ENROLLMENTS_PATH).read).fetch('enrollments')
  end

  def record_counts
    [User, Faculty, Department, Student, Course, StudentCourse, PlannedCourse].to_h do |model|
      [model.name, model.count]
    end
  end
end

