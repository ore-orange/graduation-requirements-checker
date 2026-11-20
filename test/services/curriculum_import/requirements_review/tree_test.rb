# frozen_string_literal: true

require 'test_helper'

# 確認画面のツリー。小計を「行を囲む枠」にし、算入上限を「その区分を数える行の内側」に出す決め方。
# 文書の形は変えないので、置き場所はここだけで決まる(設計書 項目4・10)。
class RequirementsReviewTreeTest < ActiveSupport::TestCase
  Tree = CurriculumImport::RequirementsReview::Tree

  def row(id, categories = [])
    { 'id' => id, 'name' => "行#{id}", 'categories' => categories, 'check_ids' => [] }
  end

  def tree(groups:, subtotals: [], rules: [])
    document = { 'categories' => [], 'courses' => [], 'rules' => rules,
                 'display' => { 'total_credits' => 10, 'groups' => groups, 'subtotals' => subtotals } }
    Tree.new(CurriculumImport::Validation::Input.new(document, []))
  end

  # ---- 小計は、まとめている行を囲む枠にする(項目10) ----

  # nodes_of は [節点, 行の位置] の組を返す。行の位置は、その章の rows の中の添字(欄の名前に使う)。
  def names(nodes) = nodes.map { |node, _| node.is_a?(Tree::Frame) ? node.id : node['id'] }

  test '行が連続している小計は、その行を囲む枠になる' do
    groups = [{ 'id' => 'g', 'rows' => [row('a'), row('b'), row('c'), row('d')] }]
    subtotals = [{ 'id' => 'sub', 'name' => '合計', 'required_credits' => 6, 'row_ids' => %w[b c] }]

    nodes = tree(groups: groups, subtotals: subtotals).nodes_of(0)

    assert_equal %w[a sub d], names(nodes)
    assert_equal [0, 1, 3], nodes.map(&:last)
    frame = nodes[1].first
    assert_equal %w[b c], frame.rows.pluck('id')
    assert_equal [0, 1], [frame.index, frame.row_index]
  end

  test '枠になった小計は、章の後ろには並べない' do
    groups = [{ 'id' => 'g', 'rows' => [row('a'), row('b')] }]
    subtotals = [{ 'id' => 'sub', 'name' => '合計', 'required_credits' => 6, 'row_ids' => %w[a b] }]

    assert_empty tree(groups: groups, subtotals: subtotals).loose_subtotals
  end

  # 行が連続していない小計は枠にできない。黙って消すと、その小計が画面から無くなる。
  test '行が連続していない小計は、枠にせず章の後ろに並べる' do
    groups = [{ 'id' => 'g', 'rows' => [row('a'), row('b'), row('c')] }]
    subtotals = [{ 'id' => 'sub', 'name' => '合計', 'required_credits' => 6, 'row_ids' => %w[a c] }]
    built = tree(groups: groups, subtotals: subtotals)

    assert_equal %w[a b c], names(built.nodes_of(0))
    assert_equal([['sub', 0]], built.loose_subtotals.map { |subtotal, index| [subtotal['id'], index] })
  end

  test '章をまたぐ小計・行の無い小計は、枠にせず章の後ろに並べる' do
    groups = [{ 'id' => 'g1', 'rows' => [row('a')] }, { 'id' => 'g2', 'rows' => [row('b')] }]
    subtotals = [{ 'id' => 'across', 'row_ids' => %w[a b] }, { 'id' => 'empty', 'row_ids' => [] },
                 { 'id' => 'unknown', 'row_ids' => %w[nope] }]
    built = tree(groups: groups, subtotals: subtotals)

    assert_equal(%w[across empty unknown], built.loose_subtotals.map { |subtotal, _| subtotal['id'] })
    assert_equal %w[a], names(built.nodes_of(0))
  end

  test '同じ行を指す小計が2つあるときは、先に来た小計だけが枠になる' do
    groups = [{ 'id' => 'g', 'rows' => [row('a'), row('b')] }]
    subtotals = [{ 'id' => 'first', 'row_ids' => %w[a b] }, { 'id' => 'second', 'row_ids' => %w[a b] }]
    built = tree(groups: groups, subtotals: subtotals)

    assert_equal ['first'], built.framed_ids
    assert_equal(['second'], built.loose_subtotals.map { |subtotal, _| subtotal['id'] })
  end

  # ---- 算入上限は、その区分を数える行の内側に出す(項目4) ----

  test '算入上限は、その区分を数える行の内側に出る' do
    groups = [{ 'id' => 'g', 'rows' => [row('health', %w[health]), row('general', %w[humanities natural])] }]
    rules = [{ 'id' => 'natural_cap', 'type' => 'cap', 'category' => 'natural', 'credits' => 2 }]
    built = tree(groups: groups, subtotals: [], rules: rules)

    assert_equal ['natural_cap'], built.caps_of(row('general', %w[humanities natural])).pluck('id')
    assert_empty built.caps_of(row('health', %w[health]))
  end

  test 'どの行の区分にも当たらない算入上限は、行の内側には出さない' do
    groups = [{ 'id' => 'g', 'rows' => [row('health', %w[health])] }]
    rules = [{ 'id' => 'natural_cap', 'type' => 'cap', 'category' => 'natural', 'credits' => 2 }]
    built = tree(groups: groups, subtotals: [], rules: rules)

    assert_empty built.caps_of(row('health', %w[health]))
  end

  # ---- 実物の2024年度 ----

  test '実物の2024年度では、小計1件が専門選択の3行を囲み、自然系の上限が教養・総合領域の行に出る' do
    document = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    built = Tree.new(CurriculumImport::Validation::Input.new(document, []))
    elective = document['display']['groups'].index { |group| group['id'] == 'elective' }

    nodes = built.nodes_of(elective)
    assert_equal %w[elective_inner fusion free], names(nodes)
    assert_equal %w[elective_math advanced related], nodes.first.first.rows.pluck('id')
    assert_empty built.loose_subtotals

    general = document['display']['groups'][0]['rows'].find { |entry| entry['id'] == 'general_subtotal' }
    assert_equal ['natural_cap'], built.caps_of(general).pluck('id')
  end
end

