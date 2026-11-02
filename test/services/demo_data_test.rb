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
    # 学部・学科のマスタは環境を問わず作られるので、先にseed全体を流しておく。
    # そのうえで、無効な環境で流してもレコードが1件も増えないことを確かめる。
    load Rails.root.join('db/seeds.rb')
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

  test '2025年度入学のデモ学生ができる' do
    assert_equal [2024, 2025], DemoAccount.students.map(&:admission_year).sort
  end

  test '2025年度の学生は2025年度の便覧で判定される' do
    assert_equal 2025, DemoAccount.students.last.curriculum.admission_year
  end

  test '2025年度の便覧がなければ2025年度の学生は作らない' do
    Curriculum.where(admission_year: 2025).destroy_all
    assert_equal 1, DemoData.load!.size
  end

  test 'loading repeatedly preserves plans unrelated data and non-seeded history' do
    students = DemoData.load!
    student = students.first
    course = student.student_courses.first.course
    plan = student.planned_courses.create!(course: course, academic_year: 2026, semester: '後期')
    history = student.student_courses.create!(course: course, academic_year: 2023, semester: 'manual-test',
                                              grade: 'manual-result', enrollment_status: 'unknown',
                                              credits_earned: '1.5', approval_confirmed: false)
    unrelated_user = User.create!(email: 'unrelated@example.test')
    unrelated_course = Course.create!(course_number: course.course_number, name: course.name, credits: 9)
    unrelated_student = Student.create!(user: unrelated_user, department: student.department, admission_year: 2025)
    unrelated_plan = unrelated_student.planned_courses.create!(course: unrelated_course,
                                                               academic_year: 2026, semester: '後期')
    before_counts = record_counts
    before_history = history.attributes
    before_course = unrelated_course.attributes

    2.times { assert_equal students, DemoData.load! }

    assert_equal before_counts, record_counts
    assert_equal plan, student.planned_courses.find(plan.id)
    assert_equal unrelated_plan, unrelated_student.planned_courses.find(unrelated_plan.id)
    assert_equal before_history, history.reload.attributes
    assert_equal before_course, unrelated_course.reload.attributes
    assert_equal unrelated_user, User.find(unrelated_user.id)
  end

  test 'unverified source credits stay unknown rather than being fabricated' do
    document = curriculum
    number = demo_enrollments.first.fetch('course_number')
    entry = document.fetch('courses').find { |course| course.fetch('number') == number }
    entry['credits'] = nil
    published_curriculum.update!(document: document)
    student = DemoData.load!.first

    course = Course.find_by!(course_number: number, name: entry.fetch('name'))
    assert_nil course.credits
    current = student.student_courses.create!(course: course, academic_year: 2025, enrollment_status: 'registered')
    assert_nil current.assessment_entry.fetch(:credits)
    assert_nil current.assessment_entry.fetch(:approved)
  end

  test 'demo enrollments point at courses by number, and every number is in the handbook' do
    numbers = curriculum.fetch('courses').pluck('number').compact

    assert_equal 48, demo_enrollments.size
    assert_empty demo_enrollments.pluck('course_number') - numbers
    assert(demo_enrollments.none? { |entry| entry.key?('course_key') })
  end

  test '2025年度のデモ履修データも科目番号で便覧と対応する' do
    numbers = curriculum(2025).fetch('courses').pluck('number').compact

    assert_equal 34, demo_enrollments(2025).size
    assert_empty demo_enrollments(2025).pluck('course_number') - numbers
    assert(demo_enrollments(2025).none? { |entry| entry.key?('course_key') })
  end

  test 'the demo student is tied to the published curriculum for their admission year' do
    students = DemoData.load!

    assert_equal published_curriculum, students.first.curriculum
    assert_equal published_curriculum(2025), students.last.curriculum
  end

  test 'courses are found or created by number and name, like the timetable importer' do
    existing = Course.create!(course_number: '知能101', name: 'プログラミング演習Ⅰ', credits: 1)

    DemoData.load!

    assert_equal [existing], Course.where(course_number: '知能101', name: 'プログラミング演習Ⅰ').to_a
    assert_equal 1, Course.where(course_number: '知能101').count
  end

  test 'conflicting existing cohort is not overwritten and loading is atomic' do
    faculty = Faculty.create!(name: '既存学部')
    department = faculty.departments.create!(name: '既存学科')
    user = User.create!(email: DemoAccount.students.first.email)
    student = user.create_student!(department: department, admission_year: 2025)
    before = record_counts

    assert_raises(DemoAccount::Unavailable) { DemoData.load! }

    assert_equal before, record_counts
    assert_equal 2025, student.reload.admission_year
    assert_equal department, student.department
    assert_raises(DemoAccount::Unavailable) { DemoAccount.student }
    # 1人目(2024年度)が衝突で止まったら、2人目(2025年度)も作られない(全員まとめて1つのトランザクション)。
    assert_nil User.find_by(email: DemoAccount.students.last.email)
  end

  test 'a conflict on the 2025 demo student rolls back the 2024 demo student too' do
    faculty = Faculty.create!(name: '既存学部')
    department = faculty.departments.create!(name: '既存学科')
    user = User.create!(email: DemoAccount.students.last.email)
    user.create_student!(department: department, admission_year: 1999)
    before = record_counts

    assert_raises(DemoAccount::Unavailable) { DemoData.load! }

    assert_equal before, record_counts
    # 2人目(2025年度)が衝突で止まったら、1人目(2024年度)が成功するはずでも作られない。
    assert_nil User.find_by(email: DemoAccount.students.first.email)
  end

  private

  def published_curriculum(year = 2024)
    Curriculum.published.find_by!(slug: 'intelligent_informatics', admission_year: year)
  end

  def curriculum(year = 2024)
    published_curriculum(year).document
  end

  def demo_enrollments(year = 2024)
    JSON.parse(Rails.root.join(DemoData::ENROLLMENT_FILES.fetch(year)).read).fetch('enrollments')
  end

  def record_counts
    [User, Faculty, Department, Student, Course, StudentCourse, PlannedCourse].to_h do |model|
      [model.name, model.count]
    end
  end
end

