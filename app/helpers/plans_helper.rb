# frozen_string_literal: true

module PlansHelper
  # 区分ごとの必要単位がなく、合計で数える区分のまとまり。計画表では合計と必要単位を1か所にまとめて出す。
  PLANNER_SUBTOTALS = [
    { id: 'elective_inner', name: '数学基礎（選択）・アドバンスト・関連の合計', req: 22,
      row_ids: %w[elective_math advanced related], check_ids: ['elective_inner'] }
  ].freeze

  # 履修計画表の学期（{ grade: 2, semester: '後期' }）を表示・URL 用の文字にする。
  def term_param(term) = "#{term[:grade]}-#{term[:semester]}"
  def term_label(term) = "#{term[:grade]}年 #{term[:semester]}"

  # 学期の単位の内訳。修得＝修得済み、履修中＝登録済み・履修中、予定＝履修予定。total はその合計。
  def term_credits(enrollments, plans, courses_by_key)
    completed = enrollments.select { |e| e.enrollment_status == 'completed' }
    current = enrollments.select { |e| StudentWorkspace::CURRENT_STATUSES.include?(e.enrollment_status) }
    credits = { earned: sum_credits(completed, &:credits_earned),
                current: sum_credits(current) { |e| e.course.credits },
                planned: sum_credits(plans) { |p| plan_credits(p, courses_by_key) } }
    credits.merge(total: credits.values.sum)
  end

  def sum_credits(records)
    records.sum(BigDecimal('0')) { |record| yield(record) || BigDecimal('0') }
  end

  def planner_subtotal_for(row_id) = PLANNER_SUBTOTALS.find { |subtotal| subtotal[:row_ids].include?(row_id) }

  # 区分の行で、便覧から選べる科目と、そのうちまだ修得・履修中・追加済みでない科目
  def row_catalogue_courses(row, courses, unavailable_keys)
    catalogue = courses.select { |c| row[:categories].include?(c['category']) && c['selectable'] == true }
    [catalogue, catalogue.select { |c| unavailable_keys.exclude?(c['key']) }]
  end
end

