# frozen_string_literal: true

module PlansHelper
  include StudentWorkspaceHelper

  # 履修計画表の学期（{ grade: 2, semester: '後期' }）を表示・URL 用の文字にする。
  def term_param(term) = "#{term[:grade]}-#{term[:semester]}"
  def term_label(term) = "#{term[:grade]}年 #{term[:semester]}"

  # 学期の単位の内訳。修得＝修得済み、履修中＝登録済み・履修中、予定＝履修予定。total はその合計。
  def term_credits(enrollments, plans, courses_by_number)
    completed = enrollments.select { |e| e.enrollment_status == 'completed' }
    current = enrollments.select { |e| StudentWorkspace::CURRENT_STATUSES.include?(e.enrollment_status) }
    credits = { earned: sum_credits(completed, &:credits_earned),
                current: sum_credits(current) { |e| e.course.credits },
                planned: sum_credits(plans) { |p| plan_credits(p, courses_by_number) } }
    credits.merge(total: credits.values.sum)
  end

  def sum_credits(records)
    records.sum(BigDecimal('0')) { |record| yield(record) || BigDecimal('0') }
  end

  # 予定カードに出す単位。便覧にも科目にも単位がなければ「未確認」と出す。
  def plan_credit_label(plan, courses_by_number)
    catalogue = courses_by_number[plan.course.course_number]
    credit_label(catalogue ? catalogue['credits'] : plan.course.credits)
  end

  # 区分ごとの必要単位がなく、合計で数える区分のまとまり。計画表では合計と必要単位を1か所にまとめて出す。
  # 便覧の display の小計のうち、その行を含むもの。
  def planner_subtotal_for(row_id, curriculum)
    subtotal = curriculum.fetch('display').fetch('subtotals').find { |entry| entry.fetch('row_ids').include?(row_id) }
    display_entry(subtotal) if subtotal
  end

  # 区分の行で、名簿から選べる科目と、そのうちまだ修得・履修中・追加済みでないもの。
  # Course の行が無い科目(course_id が nil)は、計画が指す行が無いので追加できない。
  def row_catalogue_courses(row, directory, unavailable_numbers)
    catalogue = row[:categories].flat_map { |category| directory.in_category(category) }
                                .select { |entry| entry.selectable == true }
    [catalogue, catalogue.select { |entry| entry.course_id && unavailable_numbers.exclude?(entry.number) }]
  end

  # 承認の3択（あり・なし・未回答）。値は approval_confirmed にそのまま書く値（nilは未回答に戻す）。
  def approval_choices = [[true, '承認あり'], [false, '承認なし'], [nil, '未回答']]

  def approval_button_class(selected)
    base = 'px-1.5 py-0.5 rounded text-[10px] font-semibold border cursor-pointer'
    return "#{base} bg-amber-600 text-white border-amber-600" if selected

    "#{base} bg-white border-amber-200 text-amber-800 hover:bg-amber-50"
  end
end

