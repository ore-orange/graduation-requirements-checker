# frozen_string_literal: true

require 'test_helper'

class PlansHelperTest < ActionView::TestCase
  setup do
    @curriculum = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
  end

  test '小計は便覧の display から、その行を含むものが引ける' do
    subtotal = planner_subtotal_for('advanced', @curriculum)

    assert_equal({ id: 'elective_inner', name: '数学基礎（選択）・アドバンスト・関連の合計', req: 22,
                   row_ids: %w[elective_math advanced related], check_ids: ['elective_inner'] }, subtotal)
  end

  test '小計に含まれない行は nil' do
    assert_nil planner_subtotal_for('health', @curriculum)
  end

  test '小計の行も必要単位も便覧を書き換えればその通りに変わる' do
    @curriculum['display']['subtotals'].first['required_credits'] = 20
    @curriculum['display']['subtotals'].first['row_ids'] = %w[fusion]

    assert_equal 20, planner_subtotal_for('fusion', @curriculum)[:req]
    assert_nil planner_subtotal_for('advanced', @curriculum)
  end
end

