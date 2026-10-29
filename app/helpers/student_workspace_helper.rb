# frozen_string_literal: true

module StudentWorkspaceHelper
  # 便覧の display は JSON なので文字列キー。ビューは symbol キーで引くので、ここで一度だけ変換する。
  # 必要単位は JSON では required_credits・required_label、ビューでは req・req_label と呼ぶ。
  DISPLAY_KEYS = { 'required_credits' => :req, 'required_label' => :req_label }.freeze

  ENROLLMENT_LABELS = { 'completed' => '修得済み', 'registered' => '履修登録済み', 'in_progress' => '履修中',
                        'failed' => '未修得', 'unknown' => '状態未確認' }.freeze

  def enrollment_status_label(status) = ENROLLMENT_LABELS.fetch(status, '状態未確認')
  def credit_label(credits) = credits.nil? ? '未確認' : "#{credit_number(credits)} 単位"

  # 画面の章。便覧の display を、章 → 行の順にシンボルキーへ直して返す。display が無い便覧は KeyError にする。
  def planner_groups(curriculum)
    curriculum.fetch('display').fetch('groups').map do |group|
      display_entry(group.except('rows')).merge(rows: group.fetch('rows').map { |row| display_entry(row) })
    end
  end

  def category_label(category, curriculum)
    curriculum.fetch('categories').find { |entry| entry['key'] == category }&.fetch('label') || category
  end

  def find_check(snapshot, check_id) = snapshot.checks.find { |check| check.id == check_id }
  def source_url(source) = (source['url'].to_s if source['url'].to_s.start_with?('https://', 'http://'))

  def credit_number(val) = val.nil? ? '0' : number_with_precision(val, precision: 2, strip_insignificant_zeros: true)

  def catalogue_availability(course, unavailable_numbers:, persisted_numbers:)
    return '追加済み・修得済み・履修中' if unavailable_numbers.include?(course['number'])
    return '選択対象外' unless course['selectable'] == true
    # 科目番号で Course に当てるので、番号の無い科目は選べない。
    return '科目番号が未掲載のため選択できません' if course['number'].blank?

    '初期データ未登録' unless persisted_numbers.include?(course['number'])
  end

  # 便覧の科目表に科目番号で当たればその区分。当たらなければ、自由入力計画科目はその科目が持つ区分、それ以外は算入対象外。
  def course_category(course, courses_by_number)
    entry = courses_by_number[course.course_number]
    return entry['category'] if entry

    course.custom? ? course.custom_category : 'excluded'
  end

  def category_credits(enrollments, plans, categories, courses_by_number)
    in_cat = filter_by_categories(enrollments, categories, courses_by_number)
    earned = in_cat.select { |i| i.enrollment_status == 'completed' }.sum(BigDecimal('0')) { |i| i.credits_earned.to_d }
    current = in_cat.select { |i| StudentWorkspace::CURRENT_STATUSES.include?(i.enrollment_status) }
                    .sum(BigDecimal('0')) { |i| i.course.credits.to_d }
    planned = filter_by_categories(plans, categories, courses_by_number)
              .sum(BigDecimal('0')) { |p| plan_credits(p, courses_by_number) }
    { earned: earned, planned: current + planned }
  end

  def filter_by_categories(records, categories, courses_by_number)
    records.select { |item| categories.include?(course_category(item.course, courses_by_number)) }
  end

  def plan_credits(plan, courses_by_number)
    catalogue = courses_by_number[plan.course.course_number]
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

  private

  # 便覧の display の1要素（章・行・小計）をシンボルキーに直す。この境界は1か所だけ。
  def display_entry(entry) = entry.to_h { |key, value| [DISPLAY_KEYS.fetch(key) { key.to_sym }, value] }
end

