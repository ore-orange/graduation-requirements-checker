# frozen_string_literal: true

# 区分のカードと、開いたときに出る内訳で同じ数字を使うためのまとめ役。
# ダッシュボードと内訳フレームの2箇所から呼ぶので、ビューには計算を置かない。
class DashboardMetrics
  include StudentWorkspaceHelper

  GRADUATION_CREDITS = 130

  attr_reader :assessment, :enrollments, :plans, :courses_by_key

  def initialize(assessment:, enrollments:, plans:, courses_by_key:)
    @assessment = assessment
    @enrollments = enrollments
    @plans = plans
    @courses_by_key = courses_by_key
  end

  def custom_plans
    @custom_plans ||= plans.select { |plan| custom_course?(plan.course.curriculum_key) }
  end

  def custom_credits(categories)
    custom_plans.select { |plan| categories.include?(course_category(plan.course.curriculum_key, courses_by_key)) }
                .sum(BigDecimal('0')) { |plan| plan_credits(plan, courses_by_key) }
  end

  # 卒業必要単位(130)に対する合計。カード上部のバーで使う。
  def total(earned, planned)
    bar(GRADUATION_CREDITS, earned, planned).merge(
      status: assessment.actual.status == :satisfied ? :satisfied : :unmet,
      review: assessment.projected.status == :needs_review
    )
  end

  # 区分1つぶんの修得済み・見込み・ステータス
  def group(definition)
    categories = definition[:rows].flat_map { |row| row[:categories] }
    actual = find_check(assessment.actual, definition[:check_id])
    projected = find_check(assessment.projected, definition[:check_id])
    extra = custom_credits(categories)
    earned = actual ? actual.counted_credits : BigDecimal('0')
    planned = ((projected ? projected.counted_credits : BigDecimal('0')) - earned) + extra
    bar(definition[:req], earned, planned).merge(judgement(actual, projected, extra))
  end

  # 内訳1行ぶんの修得済み・見込み・ステータス・不足科目
  def row(definition)
    extra = custom_credits(definition[:categories])
    earned, planned = row_credits(definition, extra)
    target = definition[:req] || (definition[:id] == 'free' ? 37 : 22)
    missing = assessment.projected.checks.select { |check| definition[:check_ids].include?(check.id) }
                        .flat_map(&:missing_courses).uniq
    raw = row_check_status(assessment, definition[:check_ids], has_custom_plan: extra.positive?)
    bar(target, earned, planned).merge(
      status: raw == :satisfied ? :satisfied : :unmet,
      review: raw == :needs_review,
      missing: missing
    )
  end

  private

  # 判定は充足か不足の二択。履修中と要確認は別の軸なので、判定とは分けて持つ。
  def judgement(actual, projected, extra)
    { status: actual&.status == :satisfied ? :satisfied : :unmet,
      review: extra.positive? || projected&.status == :needs_review }
  end

  # 専門選択の内数3区分と自由科目は、区分単位の集計ではなく判定側の算入単位を使う
  def row_credits(definition, extra)
    actual = find_check(assessment.actual, definition[:check_ids].first)
    projected = find_check(assessment.projected, definition[:check_ids].first)
    if %w[general_subtotal fusion].include?(definition[:id]) && actual&.counted_credits && projected&.counted_credits
      [actual.counted_credits, (projected.counted_credits - actual.counted_credits) + extra]
    else
      credits = category_credits(enrollments, plans, definition[:categories], courses_by_key)
      [credits[:earned], credits[:planned]]
    end
  end

  def bar(target, earned, planned)
    earned_pct = (earned.to_f / target * 100).round.clamp(0, 100)
    { earned: earned, planned: planned, req: target, earned_pct: earned_pct,
      planned_pct: (planned.to_f / target * 100).round.clamp(0, 100 - earned_pct) }
  end
end

