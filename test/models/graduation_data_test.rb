# frozen_string_literal: true

require 'test_helper'

# DB制約を検証するテストでは意図的にModelの検証を迂回する。
# rubocop:disable-next Rails/SkipsModelValidations
class GraduationDataTest < ActiveSupport::TestCase
  setup do
    @faculty = Faculty.create!(name: 'テスト学部')
    @department = Department.create!(faculty: @faculty, name: 'テスト学科')
    @user = User.create!(email: 'student@example.test')
    @student = Student.create!(user: @user, department: @department, admission_year: 2024)
    @program = Program.create!(department: @department, name: 'テストプログラム')
    @course = Course.create!(course_number: 'TEST-01', name: 'テスト科目', credits: 2)
  end

  test 'associations work and students may have no assigned program' do
    assert_equal @student, @user.student
    assert_equal @faculty, @student.department.faculty
    assert_includes @faculty.departments, @department
    assert_includes @department.programs, @program
    assert_includes @department.students, @student
    assert_empty @student.programs
  end

  test 'email is normalized and unique regardless of case' do
    user = User.create!(email: ' OTHER@EXAMPLE.TEST ')
    assert_equal 'other@example.test', user.email
    assert_not User.new(email: 'STUDENT@EXAMPLE.TEST').valid?
    assert_not User.new(email: 'invalid').valid?
    assert_not User.new.valid?

    assert_raises(ActiveRecord::RecordNotUnique) do
      User.transaction(requires_new: true) do
        User.insert_all!([{ email: 'STUDENT@EXAMPLE.TEST' }])
      end
    end
  end

  test 'one student per user is enforced by model and database' do
    assert_not Student.new(user: @user, department: @department, admission_year: 2025).valid?
    assert_raises(ActiveRecord::RecordNotUnique) do
      Student.transaction(requires_new: true) do
        Student.insert_all!([{ user_id: @user.id, department_id: @department.id, admission_year: 2025 }])
      end
    end
  end

  test 'course names and numbers are not identity or unique constraints' do
    duplicate = Course.create!(course_number: @course.course_number, name: @course.name, credits: 3)
    assert_not_equal @course.id, duplicate.id
    assert Course.create!(name: '番号・単位未確認').persisted?
  end

  test 'retakes and credits earned are independent of catalog changes' do
    failed = @student.student_courses.create!(course: @course, academic_year: 2024,
                                              semester: 'test-term', grade: 'test-fail', credits_earned: 0)
    passed = @student.student_courses.create!(course: @course, academic_year: 2025,
                                              semester: 'test-term', grade: 'test-pass', credits_earned: '1.5')
    @course.update!(course_number: 'TEST-NEW', credits: 3)

    assert_equal 0, failed.reload.credits_earned
    assert_equal BigDecimal('1.5'), passed.reload.credits_earned
    assert_equal @course, passed.course
    assert_equal [@course.id, @course.id], @student.courses.pluck(:id)
    assert_includes @course.students, @student
    assert @student.student_courses.create!(course: @course, academic_year: 2025, semester: 'test-term').persisted?
  end

  test 'program changes retain previous assignment records' do
    previous = @student.student_program_assignments.create!(program: @program, status: 'test-ended',
                                                            assigned_at: Time.zone.local(2024, 4, 1),
                                                            ended_at: Time.zone.local(2025, 3, 31))
    next_program = Program.create!(department: @department, name: '別テストプログラム')
    current = @student.student_program_assignments.create!(program: next_program, status: 'test-assigned',
                                                           assigned_at: Time.zone.local(2025, 4, 1))
    assert_equal [previous, current], @student.student_program_assignments.order(:assigned_at).to_a
    assert_includes @program.students, @student
    assert_includes @student.programs, next_program
    assert @student.student_program_assignments.new(program: @program, status: 'test-pending').valid?
  end

  test 'invalid numeric values and assignment dates are rejected by models' do
    assert_not @student.tap { |student| student.admission_year = 0 }.valid?
    assert_not Course.new(name: 'test', credits: -1).valid?
    assert_not StudentCourse.new(student: @student, course: @course, academic_year: 2024, credits_earned: -1).valid?
    assert_not StudentCourse.new(student: @student, course: @course, academic_year: 0).valid?
    assert_not StudentProgramAssignment.new(student: @student, program: @program, status: '').valid?
    assert_not StudentProgramAssignment.new(student: @student, program: @program, status: 'test',
                                            ended_at: Time.current).valid?
    assert_not StudentProgramAssignment.new(student: @student, program: @program, status: 'test',
                                            assigned_at: Time.current, ended_at: 1.day.ago).valid?
  end

  test 'foreign keys block missing parents for every relationship' do
    [
      [Department, { faculty_id: -1, name: 'test' }],
      [Program, { department_id: -1, name: 'test' }],
      [Student, { user_id: -1, department_id: @department.id, admission_year: 2024 }],
      [Student, { user_id: User.create!(email: 'other@example.test').id, department_id: -1, admission_year: 2024 }],
      [StudentCourse, { student_id: -1, course_id: @course.id, academic_year: 2024 }],
      [StudentCourse, { student_id: @student.id, course_id: -1, academic_year: 2024 }],
      [StudentProgramAssignment, { student_id: -1, program_id: @program.id, status: 'test' }],
      [StudentProgramAssignment, { student_id: @student.id, program_id: -1, status: 'test' }]
    ].each do |model, attributes|
      assert_raises(ActiveRecord::InvalidForeignKey) do
        model.transaction(requires_new: true) { model.insert_all!([attributes]) }
      end
    end
  end

  test 'database checks reject invalid units years and chronology without validation' do
    [
      [@student, { admission_year: 0 }],
      [@course, { credits: -1 }],
      [@student.student_courses.create!(course: @course, academic_year: 2024), { academic_year: 0 }],
      [@student.student_courses.create!(course: @course, academic_year: 2024), { credits_earned: -1 }],
      [@student.student_program_assignments.create!(program: @program, status: 'test'), { ended_at: Time.current }]
    ].each do |record, attributes|
      assert_raises(ActiveRecord::StatementInvalid) do
        record.class.transaction(requires_new: true) { record.update_columns(attributes) }
      end
    end
  end

  test 'database not null constraints reject incomplete records' do
    assert_raises(ActiveRecord::NotNullViolation) do
      @course.class.transaction(requires_new: true) { @course.update_columns(name: nil) }
    end
    assert_raises(ActiveRecord::NotNullViolation) do
      @student.class.transaction(requires_new: true) { @student.update_columns(department_id: nil) }
    end
  end

  test 'deletion never silently removes student history' do
    @student.student_courses.create!(course: @course, academic_year: 2024)
    assert_not @student.destroy
    assert_not @course.destroy
    assert_not @user.destroy
    assert_not @department.destroy
    assert_not @faculty.destroy
    @student.student_program_assignments.create!(program: @program, status: 'test')
    assert_not @program.destroy

    assert_raises(ActiveRecord::InvalidForeignKey) do
      Student.transaction(requires_new: true) { @student.delete }
    end
  end
end

