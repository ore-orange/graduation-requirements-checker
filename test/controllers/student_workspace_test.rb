# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class StudentWorkspaceTest < ActionDispatch::IntegrationTest
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
      get root_path, env: local_env
    end

    assert_response :success
    assert_select '[data-assessment="actual"]', count: 1
    assert_select '[data-assessment="projected"]', count: 1
    assert_select '[data-plan]', count: 0

    @student.student_courses.group_by { |e| [e.academic_year, e.semester] }.each do |(year, semester), enrollments|
      get plan_path(term: "#{year - @student.admission_year + 1}-#{semester}"), env: local_env

      enrollments.each { |enrollment| assert_select "[data-enrollment='#{enrollment.id}']", count: 1 }
    end
    assert_select 'form input[name="student_id"]', count: 0
    assert_select 'form[action*="student_courses"]', count: 0
  end

  test 'adds persists restores and removes a planned course without changing history' do
    original_history = @student.student_courses.order(:id).map(&:attributes)
    get root_path, env: local_env
    original_actual = assessment_attributes('actual')
    original_projected_credits = BigDecimal(assessment_attributes('projected').fetch('data-counted-credits'))

    assert_difference '@student.planned_courses.count', 1 do
      post plan_courses_path, params: { course_key: @candidate.fetch('key') }, env: local_env
    end
    assert_response :see_other
    assert_redirected_to plan_path
    plan = @student.planned_courses.find_by!(course: course_record(@candidate))

    get plan_path, env: local_env
    assert_response :success
    assert_select "[data-plan='#{plan.id}'][data-course-key='#{@candidate.fetch('key')}']", count: 1

    get root_path, env: local_env
    assert_equal original_actual, assessment_attributes('actual')
    assert_operator BigDecimal(assessment_attributes('projected').fetch('data-counted-credits')), :>=,
                    original_projected_credits

    # A fresh request restores the persisted plan rather than relying on submitted state.
    get plan_path, env: local_env
    assert_select "[data-plan='#{plan.id}']", count: 1

    assert_difference '@student.planned_courses.count', -1 do
      delete plan_course_path(plan), env: local_env
    end
    assert_response :see_other
    assert_redirected_to plan_path
    get plan_path, env: local_env
    assert_select '[data-plan]', count: 0

    get root_path, env: local_env
    assert_equal original_actual, assessment_attributes('actual')
    assert_equal original_projected_credits,
                 BigDecimal(assessment_attributes('projected').fetch('data-counted-credits'))
    assert_equal original_history, @student.student_courses.reload.order(:id).map(&:attributes)
  end

  test 'future mandatory courses improve the projected requirement but not actual history' do
    get root_path, env: local_env
    assert_select '[data-assessment="projected"] [data-check="required_all"][data-status="unmet"]', count: 1
    original_actual = assessment_attributes('actual')
    initial_credits = BigDecimal(assessment_attributes('projected').fetch('data-counted-credits'))
    future_required = @courses.select { |course| course['required'] && @occupied_keys.exclude?(course.fetch('key')) }

    future_required.each do |course|
      post plan_courses_path, params: { course_key: course.fetch('key') }, env: local_env
      assert_response :see_other
    end

    get root_path, env: local_env
    assert_select '[data-assessment="projected"] [data-check="required_all"][data-status="satisfied"]', count: 1
    assert_select '[data-assessment="actual"] [data-check="required_all"][data-status="unmet"]', count: 1
    assert_select '[data-assessment="projected"][data-status="satisfied"]', count: 1
    assert_equal original_actual, assessment_attributes('actual')
    assert_operator BigDecimal(assessment_attributes('projected').fetch('data-counted-credits')), :>, initial_credits

    plan = @student.planned_courses.find_by!(course: course_record(future_required.first))
    delete plan_course_path(plan), env: local_env
    get root_path, env: local_env
    assert_select '[data-assessment="projected"] [data-check="required_all"][data-status="unmet"]', count: 1
    assert_select '[data-assessment="projected"][data-status="unmet"]', count: 1
  end

  test 'rejects completed current duplicate unknown and nonselectable courses' do
    prohibited = @courses.find { |course| course['selectable'] != true }
    assert_not_nil prohibited
    keys = @occupied_keys + [prohibited.fetch('key'), 'not-a-catalogue-course', nil, ['not-a-string']]
    keys.each do |key|
      assert_no_difference 'PlannedCourse.count' do
        post plan_courses_path, params: { course_key: key }, env: local_env
      end
      assert_response :see_other
      assert_redirected_to plan_path
    end

    post plan_courses_path, params: { course_key: @candidate.fetch('key') }, env: local_env
    assert_no_difference 'PlannedCourse.count' do
      post plan_courses_path, params: { course_key: @candidate.fetch('key') }, env: local_env
    end
    assert_response :see_other
  end

  test 'ignores account selectors and cannot delete another students plan' do
    other = Student.create!(user: User.create!(email: 'other-demo-ui@example.test'),
                            department: @student.department, admission_year: 2024)
    foreign_plan = other.planned_courses.create!(course: course_record(@candidate))

    assert_no_difference 'PlannedCourse.count' do
      delete plan_course_path(foreign_plan), params: { student_id: other.id }, env: local_env
    end
    assert_response :not_found
    assert foreign_plan.reload.persisted?

    request_params = { course_key: @candidate.fetch('key'), student_id: other.id, account: other.user.email }

    assert_difference '@student.planned_courses.count', 1 do
      assert_no_difference 'other.planned_courses.count' do
        post plan_courses_path, params: request_params, env: local_env
      end
    end
    assert_response :see_other
    get plan_path, params: { student_id: other.id, account: other.user.email }, env: local_env
    assert_select "[data-plan='#{foreign_plan.id}']", count: 0
  end

  test 'catalogue search filters visible courses by name and category' do
    get plan_path, params: { q: @candidate.fetch('name'), category: @candidate.fetch('category') },
                   env: local_env
    assert_response :success
    assert_select "[data-catalogue-key='#{@candidate.fetch('key')}']", count: 1
    @courses.reject { |course| course['category'] == @candidate.fetch('category') }.each do |course|
      assert_select "[data-catalogue-key='#{course.fetch('key')}']", count: 0
    end

    get plan_path, params: { q: 'does-not-exist-in-the-catalogue' }, env: local_env
    assert_select '[data-catalogue-key]', count: 0
  end

  test 'unknown history is shown and makes both assessments need review without earning credits' do
    get root_path, env: local_env
    original_actual_credits = assessment_attributes('actual').fetch('data-counted-credits')
    unknown = @student.student_courses.create!(course: course_record(@candidate), academic_year: 2026,
                                               enrollment_status: 'unknown', credits_earned: nil)

    get plan_path, env: local_env

    assert_select "[data-enrollment='#{unknown.id}']", count: 1

    get root_path, env: local_env

    assert_select '[data-assessment="actual"][data-status="needs_review"]', count: 1
    assert_select '[data-assessment="projected"][data-status="needs_review"]', count: 1
    assert_equal original_actual_credits, assessment_attributes('actual').fetch('data-counted-credits')
  end

  test 'failed history is not projected as earned and may be explicitly planned again' do
    get root_path, env: local_env
    before_actual = assessment_attributes('actual')
    before_projected = assessment_attributes('projected')
    failed = @student.student_courses.create!(
      course: course_record(@candidate), academic_year: 2025, enrollment_status: 'failed', credits_earned: 0
    )

    get plan_path, env: local_env

    assert_select "[data-enrollment='#{failed.id}']", count: 1

    get root_path, env: local_env

    assert_equal before_actual, assessment_attributes('actual')
    assert_equal before_projected, assessment_attributes('projected')

    assert_difference '@student.planned_courses.count', 1 do
      post plan_courses_path, params: { course_key: @candidate.fetch('key') }, env: local_env
    end
    assert_response :see_other
    assert_equal 'failed', failed.reload.enrollment_status
  end

  test 'custom free-text course persists marks projected as needs_review and cleans up on delete' do
    get root_path, env: local_env
    original_actual = assessment_attributes('actual')

    assert_difference ['@student.planned_courses.count', 'Course.count'], 1 do
      post plan_courses_path,
           params: { custom_course: { name: '他学部情報法特論', course_number: '他学901', credits: '2', category: 'free' } },
           env: local_env
    end
    assert_response :see_other
    plan = @student.planned_courses.order(:id).last
    assert_predicate plan.course.curriculum_key, :present?
    assert plan.course.curriculum_key.start_with?('custom:free:')

    get plan_path, env: local_env
    assert_select "[data-plan='#{plan.id}']", count: 1

    get root_path, env: local_env
    assert_equal original_actual, assessment_attributes('actual')
    assert_select '[data-assessment="projected"][data-status="needs_review"]', count: 1

    assert_difference ['@student.planned_courses.count', 'Course.count'], -1 do
      delete plan_course_path(plan), env: local_env
    end
    assert_response :see_other
  end

  test 'custom course input matching catalogue course links to existing catalogue course' do
    custom = { name: @candidate.fetch('name'), course_number: '', credits: '2', category: 'advanced' }
    assert_difference '@student.planned_courses.count', 1 do
      assert_no_difference 'Course.count' do
        post plan_courses_path, params: { custom_course: custom }, env: local_env
      end
    end
    plan = @student.planned_courses.order(:id).last
    assert_equal @candidate.fetch('key'), plan.course.curriculum_key
  end

  test 'missing seed returns unavailable without creating fake data' do
    @student.user.update!(email: 'not-the-demo-account@example.test')

    assert_no_difference ['User.count', 'Student.count', 'StudentCourse.count', 'PlannedCourse.count'] do
      get root_path, env: local_env
    end
    assert_response :service_unavailable
    assert_select '[data-assessment]', count: 0

    assert_no_difference 'PlannedCourse.count' do
      post plan_courses_path, params: { course_key: @candidate.fetch('key') }, env: local_env
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
    get root_path, env: proxy_env
    assert_response :success
    assert_difference '@student.planned_courses.count', 1 do
      post plan_courses_path, params: { course_key: @candidate.fetch('key') }, env: proxy_env
    end
    assert_response :see_other
    plan = @student.planned_courses.find_by!(course: course_record(@candidate))
    assert_difference '@student.planned_courses.count', -1 do
      delete plan_course_path(plan), env: proxy_env
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

  test '履修計画表は指定した学期の履修履歴だけを表示し、前後の学期へ移動できる' do
    shown = @student.student_courses.where(academic_year: 2025, semester: '後期').to_a
    hidden = @student.student_courses.where.not(academic_year: 2025).or(
      @student.student_courses.where.not(semester: '後期')
    ).to_a
    assert shown.any? && hidden.any?, 'デモデータに2年後期とそれ以外の履修履歴がある前提'

    get plan_path(term: '2-後期'), env: local_env

    assert_select '[data-term="2-後期"]', count: 1
    shown.each { |enrollment| assert_select "[data-enrollment='#{enrollment.id}']", count: 1 }
    hidden.each { |enrollment| assert_select "[data-enrollment='#{enrollment.id}']", count: 0 }
    assert_select '[data-term-nav="prev"][href=?]', plan_path(term: '2-前期')
    assert_select '[data-term-nav="next"][href=?]', plan_path(term: '3-前期')
  end

  test '履修計画表は今の学期から始まり、読めない学期の指定も今の学期として扱う' do
    travel_to Date.new(2026, 10, 20) do
      get plan_path, env: local_env
      assert_select '[data-term="3-後期"]', count: 1

      get plan_path(term: '9-夏期'), env: local_env
      assert_select '[data-term="3-後期"]', count: 1
    end
  end

  test '最初と最後の学期では、その先へ進むボタンを出さない' do
    get plan_path(term: '1-前期'), env: local_env
    assert_select '[data-term-nav="prev"]', count: 0
    assert_select '[data-term-nav="next"]', count: 1

    get plan_path(term: '4-後期'), env: local_env
    assert_select '[data-term-nav="prev"]', count: 1
    assert_select '[data-term-nav="next"]', count: 0
  end

  test '学期が登録されていない履修履歴は、どの学期を見ても別枠に表示する' do
    unplaced = @student.student_courses.create!(course: course_record(@candidate), academic_year: 2025,
                                                semester: nil, enrollment_status: 'completed', credits_earned: 2)

    %w[1-前期 2-後期 4-後期].each do |term|
      get plan_path(term: term), env: local_env
      assert_select "[data-enrollment='#{unplaced.id}']", count: 1
    end
  end

  test '合計で数える3区分は、必要単位を合計の行にだけ出す' do
    get plan_path, env: local_env

    assert_select '[data-planner-subtotal="elective_inner"]', count: 1 do
      assert_select 'th', text: /必要 22/
    end
    %w[elective_math advanced related].each do |row_id|
      assert_select "[data-planner-row='#{row_id}'] th", count: 1 do |cells|
        assert_no_match(/必要/, cells.first.text, "#{row_id} には必要単位を出さない")
      end
    end
    assert_select '[data-planner-row="required_research"] th', text: /修得 \d+.*必要 16/m
  end

  test '学期を指定して追加した予定は、その学期の表にだけ出る' do
    travel_to Date.new(2026, 10, 26) do
      post plan_courses_path, params: { course_key: @candidate.fetch('key'), term: '4-前期' }, env: local_env
      assert_redirected_to plan_path(term: '4-前期')
      plan = @student.planned_courses.find_by!(course: course_record(@candidate))
      assert_equal [2027, '前期'], [plan.academic_year, plan.semester]

      get plan_path(term: '4-前期'), env: local_env
      assert_select "[data-planner-row] [data-plan='#{plan.id}']", count: 1
      assert_select '#unscheduled', count: 0

      get plan_path(term: '4-後期'), env: local_env
      assert_select "[data-plan='#{plan.id}']", count: 0
    end
  end

  test '今の学期には予定を追加でき、過去の学期と読めない学期には追加できない' do
    travel_to Date.new(2026, 10, 26) do
      assert_no_difference '@student.planned_courses.count' do
        post plan_courses_path, params: { course_key: @candidate.fetch('key'), term: '3-前期' }, env: local_env
        assert_redirected_to plan_path(term: '3-前期')
        post plan_courses_path, params: { course_key: @candidate.fetch('key'), term: '9-夏期' }, env: local_env
        assert_redirected_to plan_path
      end

      post plan_courses_path, params: { course_key: @candidate.fetch('key'), term: '3-後期' }, env: local_env
      plan = @student.planned_courses.find_by!(course: course_record(@candidate))
      assert_equal [2026, '後期'], [plan.academic_year, plan.semester]
    end
  end

  test '追加の欄は今の学期以降にだけ出る' do
    travel_to Date.new(2026, 10, 26) do
      get plan_path(term: '3-前期'), env: local_env
      assert_select '[data-add-course]', count: 0

      %w[3-後期 4-後期].each do |term|
        get plan_path(term: term), env: local_env
        assert_select '[data-add-course]', minimum: 1
        assert_select "[data-add-course] input[name='term'][value='#{term}']", minimum: 1
      end
    end
  end

  test '予定を削除したあとは見ていた学期に戻る' do
    plan = @student.planned_courses.create!(course: course_record(@candidate), academic_year: 2027, semester: '前期')

    delete plan_course_path(plan), params: { term: '4-前期' }, env: local_env

    assert_redirected_to plan_path(term: '4-前期')
    assert_not PlannedCourse.exists?(plan.id)
  end

  test '区分が複数ある行の自由入力では区分を選べ、選んだ区分で保存される' do
    travel_to Date.new(2026, 10, 26) do
      get plan_path(term: '4-前期'), env: local_env
      assert_select "[data-add-course='general_subtotal'] select[name='custom_course[category]'] option[value='social']"
      assert_select "[data-add-course='health'] input[type='hidden'][name='custom_course[category]'][value='health']"

      custom = { name: '他学部の社会系特論', credits: '2', category: 'social' }
      post plan_courses_path, params: { term: '4-前期', custom_course: custom }, env: local_env
      plan = @student.planned_courses.joins(:course).find_by!(courses: { name: '他学部の社会系特論' })
      assert_match(/\Acustom:social:/, plan.course.curriculum_key)
      assert_equal [2027, '前期'], [plan.academic_year, plan.semester]
    end
  end

  test '学期未定の履修予定は、どの学期を見ても表示する' do
    plan = @student.planned_courses.create!(course: course_record(@candidate))

    %w[1-前期 3-後期].each do |term|
      get plan_path(term: term), env: local_env
      assert_select "#unscheduled [data-plan='#{plan.id}']", count: 1
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
      get root_path, env: request_env
      assert_response :not_found
      assert_select '[data-assessment]', count: 0
      assert_select '[data-demo-setup]', count: 0

      post plan_courses_path, params: { course_key: @candidate.fetch('key') }, env: request_env
      assert_response :not_found
      delete plan_course_path(plan), env: request_env
      assert_response :not_found
    end
    plan.destroy!
  end

  test '各画面が固有のURLで表示される' do
    { root_path => '進捗ダッシュボード',
      requirements_path => '卒業要件の編集',
      plan_path => '履修計画表',
      profile_path => 'マイページ' }.each do |path, label|
      get path, env: local_env

      assert_response :success, "#{path} が表示できない"
      assert_select 'h2', text: label, count: 1
    end
  end

  test '各画面にほかの画面へのリンクがある' do
    get root_path, env: local_env

    assert_select 'a[href=?]', requirements_path
    assert_select 'a[href=?]', plan_path
    assert_select 'a[href=?]', profile_path
  end

  test '進捗ダッシュボードは履修計画表の中身を描画しない' do
    get root_path, env: local_env

    assert_select '[data-catalogue-key]', count: 0
    assert_select '[data-enrollment]', count: 0
  end

  test '科目検索のフォームとリセットは履修計画表に留まる' do
    get plan_path, env: local_env

    assert_select 'form[action=?][method=?]', plan_path, 'get'
    assert_select 'a[href=?]', plan_path, text: 'リセット'
  end
end

