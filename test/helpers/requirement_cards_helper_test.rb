# frozen_string_literal: true

require 'test_helper'

# 公開済みの卒業要件のカードの入れ子。章 → 枠 → 行 → 決まり を便覧から組み立てる。
class RequirementCardsHelperTest < ActionView::TestCase
  # 2024年度の専門選択科目を小さくした便覧。3区分をまとめた22単位の枠と、章の規則をそのまま指す行を持つ。
  def document(overrides = {})
    { 'format_version' => 2,
      'courses' => [], 'categories' => categories, 'rules' => rules,
      'display' => { 'total_credits' => 37, 'groups' => [group], 'subtotals' => [subtotal] } }.deep_merge(overrides)
  end

  def categories
    %w[elective_math advanced free humanities].map { |key| { 'key' => key, 'label' => key.upcase } }
  end

  def rules
    [{ 'id' => 'elective_inner', 'type' => 'credit_sum', 'label' => '3区分の合計',
       'categories' => %w[elective_math advanced], 'required_credits' => 22 },
     { 'id' => 'elective_total', 'type' => 'credit_sum', 'label' => '専門選択の合計',
       'categories' => %w[elective_math advanced free], 'required_credits' => 37 },
     { 'id' => 'humanities', 'type' => 'credit_sum', 'label' => '人文系',
       'categories' => ['humanities'], 'required_credits' => 2 },
     { 'id' => 'paths', 'type' => 'one_of_paths', 'label' => '指定科目', 'paths' => [['role_a']] },
     { 'id' => 'choice', 'type' => 'any_of', 'label' => '選択経路',
       'options' => [{ 'type' => 'credit_sum', 'categories' => ['humanities'], 'required_credits' => 12 },
                     { 'type' => 'all_of',
                       'conditions' => [{ 'type' => 'credit_sum', 'categories' => ['humanities'],
                                          'required_credits' => 8 }] }] },
     { 'id' => 'natural_cap', 'type' => 'cap', 'category' => 'humanities', 'credits' => 2 }]
  end

  def group
    { 'id' => 'elective', 'title' => '4. 専門選択科目', 'required_credits' => 37, 'check_id' => 'elective_total',
      'rows' => [row('elective_math'), row('advanced', credits: 22), row('free', checks: ['elective_total']),
                 row('humanities', credits: 14, checks: %w[humanities paths choice])] }
  end

  def subtotal
    { 'id' => 'elective_inner', 'name' => '3区分の合計', 'required_credits' => 22,
      'row_ids' => %w[elective_math advanced], 'check_ids' => ['elective_inner'] }
  end

  def row(id, credits: nil, checks: ['elective_inner'])
    { 'id' => id, 'name' => id, 'required_credits' => credits, 'required_label' => nil,
      'categories' => [id], 'check_ids' => checks, 'credits_from_check' => false }
  end

  def deck_for(doc = document) = requirement_deck(doc)

  def find_row(doc, id) = doc['display']['groups'].first['rows'].find { |entry| entry['id'] == id }

  def frame_of(deck) = deck.tree.nodes_of(0).map(&:first).find { |node| requirement_frame?(node) }

  # 行の22は、枠に置き場所が無かったせいで真ん中の行に置かれた、枠と同じ22。両方を数字で出すと22＋22に見える。
  test '枠と同じ規則・同じ単位数を指す行は、自分の数字を出さない' do
    deck = deck_for
    frame = frame_of(deck)

    assert_not row_own_credits?(find_row(deck.document, 'advanced'), frame)
    assert_not row_own_credits?(find_row(deck.document, 'elective_math'), frame)
    assert row_own_credits?(find_row(deck.document, 'humanities'), nil)
  end

  # 行・枠・章がもう数字で言っている合計を、カードでもう一度言わない。
  test '枠・章が言っている合計は、行の下のカードにしない' do
    deck = deck_for
    rows = deck.document['display']['groups'].first['rows']
    frame = frame_of(deck)

    assert_empty rule_cards(deck, rows[0], frame, group)
    assert_empty rule_cards(deck, find_row(deck.document, 'free'), nil, group)
  end

  test '行の内訳・選択経路・算入上限は、行の下のカードになる' do
    deck = deck_for
    cards = rule_cards(deck, find_row(deck.document, 'humanities'), nil, group)

    assert_equal %w[humanities paths choice natural_cap], cards.map(&:id)
    assert_equal 2, cards.first.credits
    assert_equal 2, cards.last.limit
    assert_match(/上限/, cards.last.note)
  end

  # 「いずれかを満たす」は入れ物。単位数は中の選択肢が出す。
  test 'いずれかを満たす決まりは、選択肢を子のカードにする' do
    deck = deck_for
    choice = rule_cards(deck, find_row(deck.document, 'humanities'), nil, group).find { |card| card.id == 'choice' }

    assert choice.container?
    assert_equal 'いずれかを満たす', choice.badge
    assert_equal [12, nil], choice.children.map(&:credits)
    assert_equal 'すべて満たす', choice.children.last.badge
    assert_equal [8], choice.children.last.children.map(&:credits)
  end

  test '系列が1つだけの指定科目は、入れ物にせず一文で出す' do
    deck = deck_for
    paths = rule_cards(deck, find_row(deck.document, 'humanities'), nil, group).find { |card| card.id == 'paths' }

    assert_not paths.container?
    assert_match(/を修得/, paths.note)
  end

  test 'カードに出した決まりは、判定の規則の一覧から省く' do
    deck = deck_for

    assert_equal %w[humanities paths choice natural_cap], card_rule_ids(deck)
  end

  # 解釈できない部分を含む規則を省くと、「判定では要確認になります」の赤い知らせごと消える。
  test '解釈できない部分を含む決まりは、カードに出していても一覧から省かない' do
    doc = document
    doc['rules'].find { |rule| rule['id'] == 'choice' }['options'] = []
    deck = deck_for(doc)

    assert_equal %w[humanities paths natural_cap], card_rule_ids(deck)
  end
end

