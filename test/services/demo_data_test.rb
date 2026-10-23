# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class DemoDataTest < ActiveSupport::TestCase
  test 'demo is available only in development and test' do
    { 'development' => true, 'test' => true, 'production' => false, 'staging' => false }.each do |environment, enabled|
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new(environment)) do
        assert_equal enabled, DemoAccount.enabled?
      end
    end
  end

  test 'missing demo data raises without creating records' do
    before = record_counts
    assert_raises(DemoAccount::Unavailable) { DemoAccount.student }
    assert_equal before, record_counts
  end

  test 'disabled environments neither expose nor seed the demo account' do
    DemoData.load!
    before = record_counts
    %w[production staging].each do |environment|
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new(environment)) do
        assert_raises(DemoAccount::Unavailable) { DemoAccount.student }
        assert_raises(DemoAccount::Unavailable) { DemoData.load! }
        load Rails.root.join('db/seeds.rb')
      end
    end
    assert_equal before, record_counts
  end

  test 'loading repeatedly preserves plans unrelated data and non-seeded history' do
    student = DemoData.load!
    course = student.student_courses.first.course
    plan = student.planned_courses.create!(course: course)
    history = student.student_courses.create!(course: course, academic_year: 2023, semester: 'manual-test',
                                              grade: 'manual-result', enrollment_status: 'unknown',
                                              credits_earned: '1.5', approval_confirmed: false)
    unrelated_user = User.create!(email: 'unrelated@example.test')
    unrelated_course = Course.create!(course_number: course.course_number, name: course.name, credits: 9)
    unrelated_student = Student.create!(user: unrelated_user, department: student.department, admission_year: 2025)
    unrelated_plan = unrelated_student.planned_courses.create!(course: unrelated_course)
    before_counts = record_counts
    before_history = history.attributes
    before_course = unrelated_course.attributes

    2.times { assert_equal student, DemoData.load! }

    assert_equal before_counts, record_counts
    assert_equal plan, student.planned_courses.find(plan.id)
    assert_equal unrelated_plan, unrelated_student.planned_courses.find(unrelated_plan.id)
    assert_equal before_history, history.reload.attributes
    assert_equal before_course, unrelated_course.reload.attributes
    assert_equal unrelated_user, User.find(unrelated_user.id)
  end

  test 'unverified source credits and numbers stay unknown rather than being fabricated' do
    document = curriculum
    key = demo_enrollments.first.fetch('course_key')
    entry = document.fetch('courses').find { |course| course.fetch('key') == key }
    entry['number'] = nil
    entry['credits'] = nil
    student = CurriculumRepository.stub(:find, document) { DemoData.load! }

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
    user = User.create!(email: DemoAccount::EMAIL)
    student = user.create_student!(department: department, admission_year: 2025)
    before = record_counts

    assert_raises(DemoAccount::Unavailable) { DemoData.load! }

    assert_equal before, record_counts
    assert_equal 2025, student.reload.admission_year
    assert_equal department, student.department
    assert_raises(DemoAccount::Unavailable) { DemoAccount.student }
  end

  private

  def curriculum
    CurriculumRepository.find(department: 'intelligent_informatics', admission_year: 2024)
  end

  def demo_enrollments
    JSON.parse(Rails.root.join('db/demo_enrollments.json').read).fetch('enrollments')
  end

  def record_counts
    [User, Faculty, Department, Student, Course, StudentCourse, PlannedCourse].to_h do |model|
      [model.name, model.count]
    end
  end
end

