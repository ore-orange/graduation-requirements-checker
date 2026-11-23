# frozen_string_literal: true

module StudentWorkspaceHelper
  ENROLLMENT_LABELS = { 'completed' => '修得済み', 'registered' => '履修登録済み', 'in_progress' => '履修中',
                        'failed' => '未修得', 'unknown' => '状態未確認' }.freeze

  def enrollment_status_label(status) = ENROLLMENT_LABELS.fetch(status, '状態未確認')
  def credit_label(credits) = credits.nil? ? '未確認' : "#{credit_number(credits)} 単位"
  def custom_course?(curriculum_key) = curriculum_key.to_s.start_with?('custom:')
  def find_check(snapshot, check_id) = snapshot.checks.find { |check| check.id == check_id }
  def source_url(source) = (source['url'].to_s if source['url'].to_s.start_with?('https://', 'http://'))

  def credit_number(val) = val.nil? ? '0' : number_with_precision(val, precision: 2, strip_insignificant_zeros: true)

  def catalogue_availability(course, unavailable_keys:, persisted_keys:)
    return '追加済み・修得済み・履修中' if unavailable_keys.include?(course['key'])
    return '選択対象外' unless course['selectable'] == true

    '初期データ未登録' unless persisted_keys.include?(course['key'])
  end

  def course_category(curriculum_key, courses_by_key)
    return courses_by_key[curriculum_key]['category'] if courses_by_key.key?(curriculum_key)

    custom_course?(curriculum_key) ? curriculum_key.split(':')[1] : 'excluded'
  end

  def category_credits(enrollments, plans, categories, courses_by_key)
    in_cat = filter_by_categories(enrollments, categories, courses_by_key)
    earned = in_cat.select { |i| i.enrollment_status == 'completed' }.sum(BigDecimal('0')) { |i| i.credits_earned.to_d }
    current = in_cat.select { |i| StudentWorkspace::CURRENT_STATUSES.include?(i.enrollment_status) }
                    .sum(BigDecimal('0')) { |i| i.course.credits.to_d }
    planned = filter_by_categories(plans, categories, courses_by_key)
              .sum(BigDecimal('0')) { |p| plan_credits(p, courses_by_key) }
    { earned: earned, planned: current + planned }
  end

  def filter_by_categories(records, categories, courses_by_key)
    records.select { |item| categories.include?(course_category(item.course.curriculum_key, courses_by_key)) }
  end

  def plan_credits(plan, courses_by_key)
    catalogue = courses_by_key[plan.course.curriculum_key]
    BigDecimal((catalogue ? catalogue['credits'] : plan.course.credits).to_s, exception: false) || BigDecimal('0')
  end

  def row_check_status(assessment, check_ids, has_custom_plan: false)
    actual = checks_by_ids(assessment.actual, check_ids)
    return :needs_review if has_custom_plan || any_review?(actual)
    return :satisfied if all_satisfied?(actual)

    projected_row_status(checks_by_ids(assessment.projected, check_ids))
  end

  def projected_row_status(checks)
    return :needs_review if any_review?(checks)

    all_satisfied?(checks) ? :projected : :unmet
  end

  def checks_by_ids(snapshot, check_ids) = snapshot.checks.select { |check| check_ids.include?(check.id) }
  def any_review?(checks) = checks.any? { |check| check.status == :needs_review }
  def all_satisfied?(checks) = checks.present? && checks.all? { |check| check.status == :satisfied }
end

