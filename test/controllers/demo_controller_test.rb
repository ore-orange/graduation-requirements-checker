# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class DemoControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
    DemoData.load!
    @student = DemoAccount.student
    @student.planned_courses.delete_all
    @curriculum = CurriculumRepository.find(department: 'intelligent_informatics', admission_year: 2024)
    @courses = @curriculum.fetch('courses')
    @occupied_keys = @student.student_courses.where(enrollment_status: %w[completed registered in_progress])
                             .joins(:course).pluck('courses.curriculum_key')
    @candidate = @courses.find { |course| course['selectable'] == true && @occupied_keys.exclude?(course['key']) }
  end

  teardown do
    if @previous_proxy.nil?
      ENV.delete('LOCAL_DEMO_PROXY')
    else
      ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
    end
  end

  test 'reads persisted history and starts with an empty plan without creating data' do
    assert_no_difference ['Student.count', 'StudentCourse.count', 'PlannedCourse.count'] do
      get demo_path, env: local_env
    end

    assert_response :success
    assert_select '[data-assessment="actual"]', count: 1
    assert_select '[data-assessment="projected"]', count: 1
    assert_select '[data-plan]', count: 0
    @student.student_courses.each do |enrollment|
      assert_select "[data-enrollment='#{enrollment.id}']", count: 1
    end
    assert_select 'form input[name="student_id"]', count: 0
    assert_select 'form[action*="student_courses"]', count: 0
  end

  test 'adds persists restores and removes a planned course without changing history' do
    original_history = @student.student_courses.order(:id).map(&:attributes)
    get demo_path, env: local_env
    original_actual = assessment_attributes('actual')
    original_projected_credits = BigDecimal(assessment_attributes('projected').fetch('data-counted-credits'))

    assert_difference '@student.planned_courses.count', 1 do
      post demo_planned_courses_path, params: { course_key: @candidate.fetch('key') }, env: local_env
    end
    assert_response :see_other
    assert_redirected_to demo_path
    plan = @student.planned_courses.find_by!(course: course_record(@candidate))

    get demo_path, env: local_env
    assert_response :success
    assert_select "[data-plan='#{plan.id}'][data-course-key='#{@candidate.fetch('key')}']", count: 1
    assert_equal original_actual, assessment_attributes('actual')
    assert_operator BigDecimal(assessment_attributes('projected').fetch('data-counted-credits')), :>=,
                    original_projected_credits

    # A fresh request restores the persisted plan rather than relying on submitted state.
    get demo_path, env: local_env
    assert_select "[data-plan='#{plan.id}']", count: 1

    assert_difference '@student.planned_courses.count', -1 do
      delete demo_planned_course_path(plan), env: local_env
    end
    assert_response :see_other
    assert_redirected_to demo_path
    get demo_path, env: local_env
    assert_select '[data-plan]', count: 0
    assert_equal original_actual, assessment_attributes('actual')
    assert_equal original_projected_credits,
                 BigDecimal(assessment_attributes('projected').fetch('data-counted-credits'))
    assert_equal original_history, @student.student_courses.reload.order(:id).map(&:attributes)
  end

  test 'future mandatory courses improve the projected requirement but not actual history' do
    get demo_path, env: local_env
    assert_select '[data-assessment="projected"] [data-check="required_all"][data-status="unmet"]', count: 1
    original_actual = assessment_attributes('actual')
    initial_credits = BigDecimal(assessment_attributes('projected').fetch('data-counted-credits'))
    future_required = @courses.select { |course| course['required'] && @occupied_keys.exclude?(course.fetch('key')) }

    future_required.each do |course|
      post demo_planned_courses_path, params: { course_key: course.fetch('key') }, env: local_env
      assert_response :see_other
    end

    get demo_path, env: local_env
    assert_select '[data-assessment="projected"] [data-check="required_all"][data-status="satisfied"]', count: 1
    assert_select '[data-assessment="actual"] [data-check="required_all"][data-status="unmet"]', count: 1
    assert_select '[data-assessment="projected"][data-status="satisfied"]', count: 1
    assert_equal original_actual, assessment_attributes('actual')
    assert_operator BigDecimal(assessment_attributes('projected').fetch('data-counted-credits')), :>, initial_credits

    plan = @student.planned_courses.find_by!(course: course_record(future_required.first))
    delete demo_planned_course_path(plan), env: local_env
    get demo_path, env: local_env
    assert_select '[data-assessment="projected"] [data-check="required_all"][data-status="unmet"]', count: 1
    assert_select '[data-assessment="projected"][data-status="unmet"]', count: 1
  end

  test 'rejects completed current duplicate unknown and nonselectable courses' do
    prohibited = @courses.find { |course| course['selectable'] != true }
    assert_not_nil prohibited
    keys = @occupied_keys + [prohibited.fetch('key'), 'not-a-catalogue-course', nil, ['not-a-string']]
    keys.each do |key|
      assert_no_difference 'PlannedCourse.count' do
        post demo_planned_courses_path, params: { course_key: key }, env: local_env
      end
      assert_response :see_other
      assert_redirected_to demo_path
    end

    post demo_planned_courses_path, params: { course_key: @candidate.fetch('key') }, env: local_env
    assert_no_difference 'PlannedCourse.count' do
      post demo_planned_courses_path, params: { course_key: @candidate.fetch('key') }, env: local_env
    end
    assert_response :see_other
  end

  test 'ignores account selectors and cannot delete another students plan' do
    other = Student.create!(user: User.create!(email: 'other-demo-ui@example.test'),
                            department: @student.department, admission_year: 2024)
    foreign_plan = other.planned_courses.create!(course: course_record(@candidate))

    assert_no_difference 'PlannedCourse.count' do
      delete demo_planned_course_path(foreign_plan), params: { student_id: other.id }, env: local_env
    end
    assert_response :not_found
    assert foreign_plan.reload.persisted?

    request_params = { course_key: @candidate.fetch('key'), student_id: other.id, account: other.user.email }

    assert_difference '@student.planned_courses.count', 1 do
      assert_no_difference 'other.planned_courses.count' do
        post demo_planned_courses_path, params: request_params, env: local_env
      end
    end
    assert_response :see_other
    get demo_path, params: { student_id: other.id, account: other.user.email }, env: local_env
    assert_select "[data-plan='#{foreign_plan.id}']", count: 0
  end

  test 'catalogue search filters visible courses by name and category' do
    get demo_path, params: { q: @candidate.fetch('name'), category: @candidate.fetch('category') }, env: local_env
    assert_response :success
    assert_select "[data-catalogue-key='#{@candidate.fetch('key')}']", count: 1
    @courses.reject { |course| course['category'] == @candidate.fetch('category') }.each do |course|
      assert_select "[data-catalogue-key='#{course.fetch('key')}']", count: 0
    end

    get demo_path, params: { q: 'does-not-exist-in-the-catalogue' }, env: local_env
    assert_select '[data-catalogue-key]', count: 0
  end

  test 'unknown history is shown and makes both assessments need review without earning credits' do
    get demo_path, env: local_env
    original_actual_credits = assessment_attributes('actual').fetch('data-counted-credits')
    unknown = @student.student_courses.create!(course: course_record(@candidate), academic_year: 2026,
                                               enrollment_status: 'unknown', credits_earned: nil)

    get demo_path, env: local_env
    assert_select "[data-enrollment='#{unknown.id}']", count: 1
    assert_select '[data-assessment="actual"][data-status="needs_review"]', count: 1
    assert_select '[data-assessment="projected"][data-status="needs_review"]', count: 1
    assert_equal original_actual_credits, assessment_attributes('actual').fetch('data-counted-credits')
  end

  test 'failed history is not projected as earned and may be explicitly planned again' do
    get demo_path, env: local_env
    before_actual = assessment_attributes('actual')
    before_projected = assessment_attributes('projected')
    failed = @student.student_courses.create!(
      course: course_record(@candidate), academic_year: 2025, enrollment_status: 'failed', credits_earned: 0
    )

    get demo_path, env: local_env
    assert_select "[data-enrollment='#{failed.id}']", count: 1
    assert_equal before_actual, assessment_attributes('actual')
    assert_equal before_projected, assessment_attributes('projected')

    assert_difference '@student.planned_courses.count', 1 do
      post demo_planned_courses_path, params: { course_key: @candidate.fetch('key') }, env: local_env
    end
    assert_response :see_other
    assert_equal 'failed', failed.reload.enrollment_status
  end

  test 'custom free-text course persists marks projected as needs_review and cleans up on delete' do
    get demo_path, env: local_env
    original_actual = assessment_attributes('actual')

    assert_difference ['@student.planned_courses.count', 'Course.count'], 1 do
      post demo_planned_courses_path,
           params: { custom_course: { name: '他学部情報法特論', course_number: '他学901', credits: '2', category: 'free' } },
           env: local_env
    end
    assert_response :see_other
    plan = @student.planned_courses.order(:id).last
    assert_predicate plan.course.curriculum_key, :present?
    assert plan.course.curriculum_key.start_with?('custom:free:')

    get demo_path, env: local_env
    assert_select "[data-plan='#{plan.id}']", count: 1
    assert_equal original_actual, assessment_attributes('actual')
    assert_select '[data-assessment="projected"][data-status="needs_review"]', count: 1

    assert_difference ['@student.planned_courses.count', 'Course.count'], -1 do
      delete demo_planned_course_path(plan), env: local_env
    end
    assert_response :see_other
  end

  test 'custom course input matching catalogue course links to existing catalogue course' do
    custom = { name: @candidate.fetch('name'), course_number: '', credits: '2', category: 'advanced' }
    assert_difference '@student.planned_courses.count', 1 do
      assert_no_difference 'Course.count' do
        post demo_planned_courses_path, params: { custom_course: custom }, env: local_env
      end
    end
    plan = @student.planned_courses.order(:id).last
    assert_equal @candidate.fetch('key'), plan.course.curriculum_key
  end

  test 'missing seed returns unavailable without creating fake data' do
    @student.user.update!(email: 'not-the-demo-account@example.test')

    assert_no_difference ['User.count', 'Student.count', 'StudentCourse.count', 'PlannedCourse.count'] do
      get demo_path, env: local_env
    end
    assert_response :service_unavailable
    assert_select '[data-assessment]', count: 0

    assert_no_difference 'PlannedCourse.count' do
      post demo_planned_courses_path, params: { course_key: @candidate.fetch('key') }, env: local_env
    end
    assert_response :service_unavailable
  end

  test 'public remote addresses cannot read or mutate even with a forged forwarding header' do
    assert_demo_denied('REMOTE_ADDR' => '203.0.113.20', 'HTTP_X_FORWARDED_FOR' => '127.0.0.1')
  end

  test 'nonlocal host cannot read or mutate even from loopback' do
    host! 'www.example.com'
    assert_demo_denied(local_env)
  end

  test 'private proxy is denied unless explicitly enabled for the local host' do
    proxy_env = { 'REMOTE_ADDR' => '172.19.0.1' }
    assert_demo_denied(proxy_env)

    ENV['LOCAL_DEMO_PROXY'] = '1'
    get demo_path, env: proxy_env
    assert_response :success
    assert_difference '@student.planned_courses.count', 1 do
      post demo_planned_courses_path, params: { course_key: @candidate.fetch('key') }, env: proxy_env
    end
    assert_response :see_other
    plan = @student.planned_courses.find_by!(course: course_record(@candidate))
    assert_difference '@student.planned_courses.count', -1 do
      delete demo_planned_course_path(plan), env: proxy_env
    end
    assert_response :see_other

    assert_demo_denied('REMOTE_ADDR' => '203.0.113.20')
    host! 'www.example.com'
    assert_demo_denied(proxy_env)
  end

  test 'production denies all demo reads and writes even for enabled local proxy' do
    ENV['LOCAL_DEMO_PROXY'] = '1'
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new('production')) do
      assert_demo_denied(local_env)
      assert_demo_denied('REMOTE_ADDR' => '172.19.0.1')
    end
  end

  private

  def local_env
    { 'REMOTE_ADDR' => '127.0.0.1' }
  end

  def course_record(course)
    Course.find_by!(curriculum_key: course.fetch('key'))
  end

  def assessment_attributes(kind)
    css_select("[data-assessment='#{kind}']").first.attributes.slice('data-status',
                                                                     'data-counted-credits').transform_values(&:value)
  end

  def assert_demo_denied(request_env)
    plan = @student.planned_courses.create!(course: course_record(@candidate))
    assert_no_difference ['StudentCourse.count', 'PlannedCourse.count'] do
      get demo_path, env: request_env
      assert_response :not_found
      assert_select '[data-assessment]', count: 0
      assert_select '[data-demo-setup]', count: 0

      post demo_planned_courses_path, params: { course_key: @candidate.fetch('key') }, env: request_env
      assert_response :not_found
      delete demo_planned_course_path(plan), env: request_env
      assert_response :not_found
    end
    plan.destroy!
  end
end

