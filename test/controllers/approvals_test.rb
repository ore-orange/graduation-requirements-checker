# frozen_string_literal: true

require 'test_helper'

# 指導教員の承認が要る科目について、学生が「承認あり／なし／未回答」に答える画面と保存。
# 2024年度便覧（config/curricula/intelligent_informatics/2024.json）には承認必須の科目が実在しないため、
# setup でテスト用に1科目だけ承認必須へ立てる（本物の科目・単位・区分はそのまま使う）。
class ApprovalsTest < ActionDispatch::IntegrationTest
  # 今の学期を3年後期（2024年入学のデモ学生）に固定し、予定はこの学期に追加する。
  CURRENT_TERM = '3-後期'
  PLAN_TERM = { academic_year: 2026, semester: '後期' }.freeze

  setup do
    travel_to Date.new(2026, 10, 26)
    host! 'localhost'
    DemoData.load!
    @student = DemoAccount.student
    @student.planned_courses.delete_all

    @curriculum_record = Curriculum.published.find_by!(slug: 'intelligent_informatics', admission_year: 2024)
    document = @curriculum_record.document.deep_dup
    occupied_numbers = @student.student_courses.where(enrollment_status: %w[completed registered in_progress])
                               .joins(:course).pluck('courses.course_number')
    @approval_course = document.fetch('courses').find do |course|
      course['selectable'] == true && course['number'].present? && occupied_numbers.exclude?(course['number'])
    end
    @approval_course['requires_approval'] = true
    @curriculum_record.update!(document: document)

    @plan_course = Course.find_by!(course_number: @approval_course.fetch('number'))
    @plan = @student.planned_courses.create!(course: @plan_course, **PLAN_TERM)
  end

  teardown { travel_back }

  test '承認が要る科目の行に、承認あり・承認なし・未回答が出る' do
    get plan_path(term: CURRENT_TERM), env: local_env

    assert_response :success
    assert_select "[data-course='#{@approval_course.fetch('number')}'] button", text: '承認あり'
    assert_select "[data-course='#{@approval_course.fetch('number')}'] button", text: '承認なし'
    assert_select "[data-course='#{@approval_course.fetch('number')}'] button", text: '未回答'
  end

  test '承認が要らない科目には出ない' do
    # 知能103（離散数学）は1年前期に修得済みで、承認は要らない。
    get plan_path(term: '1-前期'), env: local_env

    assert_response :success
    assert_select "[data-course='知能103'] button", text: '承認あり', count: 0
  end

  test '未回答の予定は見込み判定でも要確認のまま' do
    assert_equal :needs_review, assess.projected.status
  end

  test '承認ありと答えると判定が確定する' do
    patch approvals_path, params: { kind: 'plan', id: @plan.id, approved: true, term: CURRENT_TERM }, env: local_env

    assert_response :see_other
    assert_equal true, @plan.reload.approval_confirmed
    assert_not_equal :needs_review, assess.projected.status
  end

  test '承認なしと答えると算入対象外になり、要確認ではなくなる(黙って算入もしない)' do
    patch approvals_path, params: { kind: 'plan', id: @plan.id, approved: false, term: CURRENT_TERM }, env: local_env

    assert_response :see_other
    assert_equal false, @plan.reload.approval_confirmed
    assert_not_equal :needs_review, assess.projected.status
  end

  test '一度承認ありと答えても、未回答に戻すと再び要確認になる' do
    @plan.update!(approval_confirmed: true)

    patch approvals_path, params: { kind: 'plan', id: @plan.id, approved: '', term: CURRENT_TERM }, env: local_env

    assert_response :see_other
    assert_nil @plan.reload.approval_confirmed
    assert_equal :needs_review, assess.projected.status
  end

  test '承認が要らない科目への回答は受け付けない' do
    other = @student.student_courses.find_by!(course: Course.find_by!(course_number: '知能103'))

    patch approvals_path, params: { kind: 'enrollment', id: other.id, approved: true, term: CURRENT_TERM },
                          env: local_env

    assert_response :unprocessable_content
    assert_nil other.reload.approval_confirmed
  end

  test '他の学生の予定には答えられない' do
    other = Student.create!(user: User.create!(email: 'other-approvals@example.test'),
                            department: @student.department, admission_year: 2024)
    foreign_plan = other.planned_courses.create!(course: @plan_course, **PLAN_TERM)

    patch approvals_path, params: { kind: 'plan', id: foreign_plan.id, approved: true, term: CURRENT_TERM },
                          env: local_env

    assert_response :not_found
    assert_nil foreign_plan.reload.approval_confirmed
  end

  private

  def local_env
    { 'REMOTE_ADDR' => '127.0.0.1' }
  end

  def assess
    get plan_path(term: CURRENT_TERM), env: local_env
    controller.instance_variable_get(:@assessment)
  end
end

