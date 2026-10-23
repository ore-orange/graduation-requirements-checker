# frozen_string_literal: true

require 'test_helper'
require 'bigdecimal'

# 判定(充足/不足)と、履修中・要確認という別軸の付記を、どう並べるかだけを見る。
class AssessmentStatusHelperTest < ActionView::TestCase
  include AssessmentStatusHelper

  def summary(status:, planned: '0', review: false)
    { status: status, planned: BigDecimal(planned), review: review }
  end

  test '充足だけのときはバッジが1つ' do
    assert_equal [%w[充足 status-satisfied]], status_badges(summary(status: :satisfied))
  end

  test '不足だけのときはバッジが1つ' do
    assert_equal [%w[不足 status-unmet]], status_badges(summary(status: :unmet))
  end

  test '充足していても履修中があれば両方出す' do
    badges = status_badges(summary(status: :satisfied, planned: '2'))

    assert_equal [%w[充足 status-satisfied], %w[履修中 status-in-progress]], badges
  end

  test '不足と履修中は同時に出る' do
    badges = status_badges(summary(status: :unmet, planned: '4'))

    assert_equal [%w[不足 status-unmet], %w[履修中 status-in-progress]], badges
  end

  test '要確認は判定と履修中のうしろに付く' do
    badges = status_badges(summary(status: :unmet, planned: '4', review: true))

    assert_equal [%w[不足 status-unmet], %w[履修中 status-in-progress], %w[要確認 status-review]], badges
  end

  test '履修中が0単位なら履修中は出さない' do
    assert_equal [%w[充足 status-satisfied]], status_badges(summary(status: :satisfied, planned: '0'))
  end

  test '画面に出すステータスは充足・不足・要確認の3つだけ' do
    assert_equal %i[satisfied unmet needs_review], AssessmentStatusHelper::STATUS_LABELS.keys
    assert_equal AssessmentStatusHelper::STATUS_LABELS.keys, AssessmentStatusHelper::STATUS_CLASSES.keys
  end
end

