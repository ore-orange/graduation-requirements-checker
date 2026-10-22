# frozen_string_literal: true

require 'test_helper'
require 'bigdecimal'

# 判定そのものは GraduationAssessment の責任。ここでは、その結果を
# カードとバーに出す形へ直すところだけを見る。
class DashboardMetricsTest < ActiveSupport::TestCase
  Check = Struct.new(:id, :status, :counted_credits, :missing_courses, keyword_init: true)
  Snapshot = Struct.new(:status, :checks, keyword_init: true)
  Assessment = Struct.new(:actual, :projected, keyword_init: true)

  GROUP = { id: 'common', title: '1. 共通教育', req: 30, check_id: 'common_total',
            rows: [{ id: 'health', name: '健康運動系', req: 2, categories: ['health'], check_ids: ['health'] }] }.freeze

  def check(id, status, credits, missing = [])
    Check.new(id: id, status: status, counted_credits: BigDecimal(credits.to_s), missing_courses: missing)
  end

  def metrics(actual:, projected:, actual_status: nil, projected_status: nil, plans: [])
    assessment = Assessment.new(
      actual: Snapshot.new(status: actual_status || actual.first&.status || :unmet, checks: actual),
      projected: Snapshot.new(status: projected_status || projected.first&.status || :unmet, checks: projected)
    )
    DashboardMetrics.new(assessment: assessment, enrollments: [], plans: plans, courses_by_key: {})
  end

  test '修得済みで足りていれば充足' do
    summary = metrics(actual: [check('common_total', :satisfied, 30)],
                      projected: [check('common_total', :satisfied, 30)]).group(GROUP)

    assert_equal :satisfied, summary[:status]
    assert_not summary[:review]
    assert_equal BigDecimal('30'), summary[:earned]
    assert_equal BigDecimal('0'), summary[:planned]
    assert_equal 100, summary[:earned_pct]
  end

  test '履修中を足せば届く場合でも、判定は不足のまま' do
    summary = metrics(actual: [check('common_total', :unmet, 26)],
                      projected: [check('common_total', :satisfied, 30)]).group(GROUP)

    # 単位はまだ修得していないので充足にはしない。届くかどうかはバーで示す。
    assert_equal :unmet, summary[:status]
    assert_equal BigDecimal('26'), summary[:earned]
    assert_equal BigDecimal('4'), summary[:planned]
  end

  test '履修中を足しても届かなければ、バーは右端まで伸びない' do
    summary = metrics(actual: [check('common_total', :unmet, 12)],
                      projected: [check('common_total', :unmet, 18)]).group(GROUP)

    assert_equal :unmet, summary[:status]
    assert_equal 40, summary[:earned_pct]
    assert_equal 20, summary[:planned_pct]
    assert_operator summary[:earned_pct] + summary[:planned_pct], :<, 100
  end

  test '判定できない項目があれば要確認を立てる' do
    summary = metrics(actual: [check('common_total', :unmet, 26)],
                      projected: [check('common_total', :needs_review, 26)]).group(GROUP)

    assert_equal :unmet, summary[:status]
    assert summary[:review]
  end

  test 'バーは必要単位を超えても100%で止める' do
    summary = metrics(actual: [check('common_total', :satisfied, 40)],
                      projected: [check('common_total', :satisfied, 48)]).group(GROUP)

    assert_equal 100, summary[:earned_pct]
    assert_equal 0, summary[:planned_pct], '修得済みで100%なら履修中ぶんの幅は残らない'
  end

  test '修得済みと履修中の合計は100%を超えない' do
    summary = metrics(actual: [check('common_total', :unmet, 27)],
                      projected: [check('common_total', :satisfied, 45)]).group(GROUP)

    assert_equal 90, summary[:earned_pct]
    assert_equal 10, summary[:planned_pct]
  end

  test '合計は実績で判定し、未確認があれば要確認を立てる' do
    subject = metrics(actual: [], projected: [], actual_status: :unmet, projected_status: :needs_review)
    total = subject.total(BigDecimal('118'), BigDecimal('4'))

    assert_equal :unmet, total[:status]
    assert total[:review]
    assert_equal 130, total[:req]
    assert_equal 91, total[:earned_pct]
    assert_equal 3, total[:planned_pct]
  end

  test '卒業必要単位を修得済みで満たしていれば合計も充足' do
    subject = metrics(actual: [], projected: [], actual_status: :satisfied, projected_status: :satisfied)
    total = subject.total(BigDecimal('130'), BigDecimal('0'))

    assert_equal :satisfied, total[:status]
    assert_not total[:review]
  end

  test '内訳の行も判定と要確認を分けて返す' do
    row = { id: 'health', name: '健康運動系', req: 2, categories: ['health'], check_ids: ['health'] }
    detail = metrics(actual: [check('health', :satisfied, 2)],
                     projected: [check('health', :satisfied, 2)]).row(row)

    assert_equal :satisfied, detail[:status]
    assert_not detail[:review]
    assert_empty detail[:missing]
  end

  test '内訳の行は未修得の指定科目を持ち帰る' do
    row = { id: 'required_research', name: '研究', req: 16,
            categories: ['required_research'], check_ids: ['required_research'] }
    detail = metrics(actual: [check('required_research', :unmet, 8)],
                     projected: [check('required_research', :unmet, 8, %w[卒業研究Ⅰ セミナーⅠ])]).row(row)

    assert_equal :unmet, detail[:status]
    assert_equal %w[卒業研究Ⅰ セミナーⅠ], detail[:missing]
  end
end

