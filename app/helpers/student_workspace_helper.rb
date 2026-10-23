# frozen_string_literal: true

module StudentWorkspaceHelper
  CATEGORY_LABELS = { 'health' => '健康運動系', 'humanities' => '人文系', 'social' => '社会系', 'natural' => '自然系',
                      'integrated' => '総合科目', 'career' => 'キャリア関係', 'regional' => '琉大特色・地域創生', 'japanese' => '日本語表現法入門',
                      'english' => '英語', 'foreign_language' => '英語以外の外国語', 'basic' => '専門基礎科目',
                      'required_information' => '情報技術系（必修）', 'required_comprehensive' => '総合力演習（必修）',
                      'required_research' => '研究・基礎演習・実験（必修）', 'required_math' => '数学基礎（必修）',
                      'required_core' => '知能情報コア（必修）', 'elective_math' => '数学基礎（選択）',
                      'advanced' => '知能情報アドバンスト', 'related' => '知能情報関連', 'fusion' => '工学融合科目',
                      'free' => '専門科目（自由）', 'excluded' => '算入対象外' }.freeze

  PLANNER_GROUPS = [
    { id: 'common', title: '1. 共通教育', req: 30, check_id: 'common_total', rows: [
      { id: 'health', name: '健康運動系', subtitle: '共通教育・教養領域', req: 2, categories: ['health'], check_ids: ['health'] },
      { id: 'general_subtotal', name: '教養・総合領域 (人文・社会・自然・総合等)', subtitle: '人文2・社会2・総合等2を含む計14単位 (自然系上限2)',
        req: 14, categories: %w[humanities social natural integrated career regional],
        check_ids: %w[general_subtotal general_without_natural humanities social general_integrated] },
      { id: 'japanese', name: '基幹領域：日本語表現法入門', subtitle: '共通教育・基幹必修',
        req: 2, categories: ['japanese'], check_ids: ['japanese'] },
      { id: 'foreign_language', name: '基幹領域：外国語科目', subtitle: '指定英語2科目必須 ／ 英語12 または 英語8＋同一外国語4',
        req: 12, categories: %w[english foreign_language], check_ids: %w[foreign_language english_required] }
    ] },
    { id: 'basic', title: '2. 専門基礎教育', req: 6, check_id: 'basic_total', rows: [
      { id: 'basic', name: '専門基礎科目 (微分積分学・物理学)', subtitle: '微積 (STⅠ・Ⅱ / 入門Ⅰ・Ⅱ) ＋ 物理 (Ⅰ / 入門Ⅰ)',
        req: 6, categories: ['basic'], check_ids: %w[basic_total calculus physics] }
    ] },
    { id: 'required', title: '3. 専門必修科目', req: 57, check_id: 'required_all', rows: [
      { id: 'required_information', name: '情報技術系', subtitle: 'プログラミング演習Ⅰ・Ⅱ (必修)', req: 2,
        categories: ['required_information'], check_ids: ['required_information'] },
      { id: 'required_comprehensive', name: '総合力演習', subtitle: '工学基礎演習・キャリアデザイン・プロジェクトデザイン (必修)',
        req: 7, categories: ['required_comprehensive'], check_ids: ['required_comprehensive'] },
      { id: 'required_research', name: '研究・基礎演習・実験', subtitle: '基礎演習Ⅰ〜Ⅳ・総合実験・ED演習・卒業研究Ⅰ・Ⅱ・セミナーⅠ・Ⅱ (必修)',
        req: 16, categories: ['required_research'], check_ids: ['required_research'] },
      { id: 'required_math', name: '数学基礎（必修）', subtitle: '工業数学Ⅰ・Ⅱ、離散数学 (必修)', req: 6,
        categories: ['required_math'], check_ids: ['required_math'] },
      { id: 'required_core', name: '知能情報コア', subtitle: '専門基幹必修 12科目', req: 26,
        categories: ['required_core'], check_ids: ['required_core'] }
    ] },
    { id: 'elective', title: '4. 専門選択科目', req: 37, check_id: 'elective_total', rows: [
      { id: 'elective_math', name: '数学基礎（選択）', subtitle: '工業数学Ⅲ・Ⅳ、確率及び統計 (内数22単位の対象)', req: nil,
        req_label: '内数22単位枠', categories: ['elective_math'], check_ids: ['elective_inner'] },
      { id: 'advanced', name: '知能情報アドバンスト', subtitle: '数学基礎(選択)・アドバンスト・関連の3区分計22単位以上', req: 22,
        req_label: '3区分計 22単位', categories: ['advanced'], check_ids: ['elective_inner'] },
      { id: 'related', name: '知能情報関連', subtitle: '技術英語・関連専門科目 (内数22単位の対象)', req: nil,
        req_label: '内数22単位枠', categories: ['related'], check_ids: ['elective_inner'] },
      { id: 'fusion', name: '工学融合科目', subtitle: '同一の他コース提供分から4単位以上', req: 4,
        categories: ['fusion'], check_ids: ['fusion_provider'] },
      { id: 'free', name: '専門科目（自由）', subtitle: '他コース・他学部等の所定専門科目 (選択全体37単位に算入)', req: nil,
        req_label: '選択全体 37単位枠', categories: ['free'], check_ids: ['elective_total'] }
    ] }
  ].freeze
  STATUS_LABELS = { satisfied: '充足', unmet: '不足あり', needs_review: '要確認' }.freeze
  STATUS_CLASSES = { satisfied: 'status-satisfied', unmet: 'status-unmet', needs_review: 'status-review' }.freeze
  ENROLLMENT_LABELS = { 'completed' => '修得済み', 'registered' => '履修登録済み', 'in_progress' => '履修中',
                        'failed' => '未修得', 'unknown' => '状態未確認' }.freeze

  def assessment_status_label(status) = STATUS_LABELS.fetch(status)
  def assessment_status_class(status) = STATUS_CLASSES.fetch(status)
  def enrollment_status_label(status) = ENROLLMENT_LABELS.fetch(status, '状態未確認')
  def credit_label(credits) = credits.nil? ? '未確認' : "#{credit_number(credits)} 単位"
  def category_label(category) = CATEGORY_LABELS.fetch(category, category)
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

