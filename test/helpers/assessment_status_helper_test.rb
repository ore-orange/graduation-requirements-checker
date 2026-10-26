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

  test '要確認でもバッジは増やさない' do
    # バッジは区分の卒業要件を満たしているかどうかだけを示す
    badges = status_badges(summary(status: :unmet, planned: '4', review: true))

    assert_equal [%w[不足 status-unmet], %w[履修中 status-in-progress]], badges
  end

  test '履修中が0単位なら履修中は出さない' do
    assert_equal [%w[充足 status-satisfied]], status_badges(summary(status: :satisfied, planned: '0'))
  end

  test 'バッジにする判定は充足と不足の2つだけ' do
    assert_equal %i[satisfied unmet], AssessmentStatusHelper::STATUS_CLASSES.keys
    # 要確認は履修計画表で単位数と並べて出すので、名前だけは残す
    assert_equal '要確認', AssessmentStatusHelper::STATUS_LABELS.fetch(:needs_review)
  end
end

