# frozen_string_literal: true

require 'test_helper'

# DB制約を検証するため、該当テストではModelの検証を意図的に迂回する。
# rubocop:disable-next Rails/SkipsModelValidations
class GraduationPlanningTest < ActiveSupport::TestCase
  setup do
    faculty = Faculty.create!(name: '計画テスト学部')
    department = faculty.departments.create!(name: '計画テスト学科')
    @student = Student.create!(user: User.create!(email: 'plan@example.test'), department: department,
                               admission_year: 2024)
    @other_student = Student.create!(user: User.create!(email: 'other-plan@example.test'), department: department,
                                     admission_year: 2024)
    @course = Course.create!(curriculum_key: 'test_course', course_number: 'TEST-1', name: '人工テスト科目', credits: 3)
  end

  test 'curriculum keys are unique while missing keys and repeated names and numbers remain valid' do
    assert_not Course.new(curriculum_key: @course.curriculum_key, name: '別名').valid?
    2.times { Course.create!(course_number: @course.course_number, name: @course.name) }

    assert_raises(ActiveRecord::RecordNotUnique) do
      Course.transaction(requires_new: true) do
        Course.insert_all!([{ curriculum_key: @course.curriculum_key, name: 'DB重複テスト' }])
      end
    end
  end

  test 'existing style histories default to unknown without inferring status or approval' do
    enrollment = @student.student_courses.create!(course: @course, academic_year: 2024,
                                                  grade: 'test-pass', credits_earned: 3)
    assert_equal 'unknown', enrollment.enrollment_status
    assert_nil enrollment.approval_confirmed
    assert_nil enrollment.assessment_entry.fetch(:credits)
    assert_not @student.student_courses.new(course: @course, enrollment_status: 'completed').valid?
  end

  test 'explicit statuses are validated by model and database' do
    assert_not @student.student_courses.new(course: @course, academic_year: 2024,
                                            enrollment_status: 'passed').valid?
    assert_raises(ActiveRecord::StatementInvalid) do
      StudentCourse.transaction(requires_new: true) do
        StudentCourse.insert_all!([{ student_id: @student.id, course_id: @course.id,
                                     academic_year: 2024, enrollment_status: 'passed' }])
      end
    end
    assert_raises(ActiveRecord::NotNullViolation) do
      StudentCourse.transaction(requires_new: true) do
        StudentCourse.insert_all!([{ student_id: @student.id, course_id: @course.id,
                                     academic_year: 2024, enrollment_status: nil }])
      end
    end
  end

  test 'assessment entries preserve earned units and explicit approval rather than deriving them' do
    completed = @student.student_courses.create!(course: @course, academic_year: 2024,
                                                 enrollment_status: 'completed', credits_earned: '1.5',
                                                 approval_confirmed: false)
    assert_equal BigDecimal('1.5'), completed.assessment_entry.fetch(:credits)
    assert_equal false, completed.assessment_entry.fetch(:approved)
    %w[registered in_progress].each do |status|
      current = @student.student_courses.create!(course: @course, academic_year: 2025,
                                                 enrollment_status: status, credits_earned: 0,
                                                 approval_confirmed: true)
      assert_equal BigDecimal('3'), current.assessment_entry.fetch(:credits)
      assert_equal true, current.assessment_entry.fetch(:approved)
    end
    @course.update!(credits: nil)
    current = @student.student_courses.create!(course: @course, academic_year: 2025,
                                               enrollment_status: 'registered')
    assert_nil current.assessment_entry.fetch(:credits)
    assert_nil current.assessment_entry.fetch(:approved)
    assert_equal BigDecimal('1.5'), completed.assessment_entry.fetch(:credits)
  end

  test 'repeated enrollment rows remain available for assessment rather than being collapsed by persistence' do
    2.times do
      @student.student_courses.create!(course: @course, academic_year: 2024,
                                       enrollment_status: 'completed', credits_earned: 3)
    end
    assert_equal 2, @student.student_courses.where(course: @course).count
  end

  test 'plans belong to their student and contain no invented year or semester' do
    plan = @student.planned_courses.create!(course: @course)
    assert_equal @student, plan.student
    assert_nil plan.academic_year
    assert_nil plan.semester
    assert_equal [@course], @student.future_courses.to_a
    assert_empty @other_student.planned_courses
    assert_empty @other_student.future_courses
    assert_raises(ActiveRecord::RecordNotFound) { @other_student.planned_courses.find(plan.id) }
  end

  test 'duplicate plans are rejected but another student can choose the same course' do
    @student.planned_courses.create!(course: @course)
    assert_not @student.planned_courses.new(course: @course).valid?
    assert @other_student.planned_courses.create!(course: @course).persisted?
    assert_raises(ActiveRecord::RecordNotUnique) do
      PlannedCourse.transaction(requires_new: true) do
        PlannedCourse.insert_all!([{ student_id: @student.id, course_id: @course.id }])
      end
    end
  end

  test 'planned course foreign keys reject missing owners and courses' do
    [{ student_id: -1, course_id: @course.id }, { student_id: @student.id, course_id: -1 }].each do |attributes|
      assert_raises(ActiveRecord::InvalidForeignKey) do
        PlannedCourse.transaction(requires_new: true) { PlannedCourse.insert_all!([attributes]) }
      end
    end
  end

  test 'plans may carry a planned term as a year and semester pair' do
    plan = @student.planned_courses.create!(course: @course, academic_year: 2027, semester: '後期')
    assert_equal 2027, plan.reload.academic_year
    assert_equal '後期', plan.semester
  end

  test 'planned terms are validated by model and database' do
    [{ academic_year: 2027, semester: nil }, { academic_year: nil, semester: '前期' },
     { academic_year: 2027, semester: '通年' }, { academic_year: 0, semester: '前期' }].each do |term|
      assert_not @student.planned_courses.new(course: @course, **term).valid?, "#{term} は保存できない"

      assert_raises(ActiveRecord::StatementInvalid, "#{term} はDBでも拒否する") do
        PlannedCourse.transaction(requires_new: true) do
          PlannedCourse.insert_all!([{ student_id: @student.id, course_id: @course.id, **term }])
        end
      end
    end
  end

  test 'removing a plan never removes enrollment history or other students plans' do
    enrollment = @student.student_courses.create!(course: @course, academic_year: 2024,
                                                  enrollment_status: 'failed', credits_earned: 0)
    plan = @student.planned_courses.create!(course: @course)
    other_plan = @other_student.planned_courses.create!(course: @course)
    assert_not @course.destroy
    plan.destroy!
    assert_equal enrollment, @student.student_courses.find(enrollment.id)
    assert_equal other_plan, @other_student.planned_courses.find(other_plan.id)
  end
end

