# frozen_string_literal: true

require 'test_helper'

class CurriculaHelperTest < ActionView::TestCase
  LABELS = { 'english' => '英語', 'foreign' => '英語以外の外国語', 'fusion' => '工学融合', 'natural' => '自然系' }.freeze

  test '規則の型ごとに、人がPDFと見比べられる文にする' do
    any_of = { 'type' => 'any_of', 'options' => [
      { 'type' => 'credit_sum', 'categories' => ['english'], 'required_credits' => 12 },
      { 'type' => 'all_of', 'conditions' => [
        { 'type' => 'credit_sum', 'categories' => ['english'], 'required_credits' => 8 },
        { 'type' => 'grouped_max', 'category' => 'foreign', 'group_by' => 'field:language', 'required_credits' => 4 }
      ] }
    ] }

    assert_equal '次のどれか: 英語の合計 12単位以上 又は (英語の合計 8単位以上 かつ 英語以外の外国語を言語ごとに数え、同じ言語から 4単位以上)',
                 rule_sentence(any_of, LABELS)
    assert_equal '次の組のどれか1つを丸ごと修得: 物理学Ⅰ ／ 物理学入門Ⅰ',
                 rule_sentence({ 'type' => 'one_of_paths', 'paths' => [%w[p1], %w[p2]] }, LABELS,
                               { 'p1' => '物理学Ⅰ', 'p2' => '物理学入門Ⅰ' })
    assert_equal '自然系は2単位まで算入', rule_sentence({ 'type' => 'cap', 'category' => 'natural', 'credits' => 2 }, LABELS)
    assert_equal '工学融合のうち提供コースがintelligent_informaticsの科目は算入しない(自コース分は不可)',
                 rule_sentence({ 'type' => 'exclude', 'category' => 'fusion', 'field' => 'provider',
                                 'value' => 'intelligent_informatics', 'reason' => '自コース分は不可' }, LABELS)
  end

  test '読み取った区分に無いキーや、知らない型は、それと分かるように出す' do
    assert_equal '読み取れていない科目区分(missing)の合計 2単位以上',
                 rule_sentence({ 'type' => 'credit_sum', 'categories' => ['missing'], 'required_credits' => 2 }, LABELS)
    assert_equal 'この条件は、読み取った形が分からないため表示できません。', rule_sentence({ 'type' => 'magic' }, LABELS)
  end

  test '調整の規則は、見出しが無ければはたらきで呼ぶ' do
    assert_equal '算入の調整', rule_title({ 'id' => 'natural_cap', 'type' => 'cap' })
    assert_equal '健康運動系', rule_title({ 'id' => 'health', 'type' => 'credit_sum', 'label' => '健康運動系' })
  end
end

