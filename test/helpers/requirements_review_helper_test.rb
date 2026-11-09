# frozen_string_literal: true

require 'test_helper'

# 要件表の確認画面が、章・行から「その行を確かめる規則」を引くための部品。
# 画面は規則を行の下に入れ子で出すので、id から規則そのものを引けることと、
# 入れ子の論理(AND/OR)を一語で言えることが要る。
class RequirementsReviewHelperTest < ActionView::TestCase
  # 画面が渡す review のうち、ここで使うのは規則の一覧だけ。
  Review = Struct.new(:rules)

  test 'rules_for は check_ids の id から規則を引く。見つからないidは含めない' do
    rule = { 'id' => 'a', 'type' => 'credit_sum' }
    review = Review.new([rule, { 'id' => 'b', 'type' => 'any_of' }])

    assert_equal [rule], rules_for(%w[a missing], review)
  end

  test 'rules_for は check_ids に並べた順で返す' do
    first = { 'id' => 'a', 'type' => 'credit_sum' }
    second = { 'id' => 'b', 'type' => 'any_of' }
    review = Review.new([first, second])

    assert_equal [second, first], rules_for(%w[b a], review)
  end

  test 'rules_for は id が空のときは何も返さない' do
    assert_empty rules_for([], Review.new([{ 'id' => 'a', 'type' => 'credit_sum' }]))
  end

  test 'rule_logic_label は one_of_paths・any_ofをOR、all_ofをAND、それ以外はnilにする' do
    assert_equal 'OR', rule_logic_label({ 'type' => 'one_of_paths' })
    assert_equal 'OR', rule_logic_label({ 'type' => 'any_of' })
    assert_equal 'AND', rule_logic_label({ 'type' => 'all_of' })
    assert_nil rule_logic_label({ 'type' => 'credit_sum' })
    assert_nil rule_logic_label({ 'type' => 'all_required' })
    assert_nil rule_logic_label({})
  end
end

