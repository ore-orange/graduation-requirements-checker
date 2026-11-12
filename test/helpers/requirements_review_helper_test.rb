# frozen_string_literal: true

require 'test_helper'

# 要件表の確認画面の部品。決まりの欄をどこに出すか(「◯以上〜◯以下」・対象の区分・入れ子・「…」の中)と、
# 入れ子の論理(AND/OR)を一語で言うこと。
class RequirementsReviewHelperTest < ActionView::TestCase
  # 入力欄(rv_*)は、保存できなかった送信の入力を残すために presenter を見る(RequirementsReview#field_value)。
  # ここで見たいのは欄の形だけなので、既定値をそのまま返す代役を置く。
  class NoSubmission
    def field_value(_name, default) = default
    def field_checked?(_name, _value, default) = default
  end

  def requirements_review = NoSubmission.new

  # 決まりの欄を、出す場所ごとに分ける(設計書 項目3・7)。
  # 判定の数字を決める欄(必要単位・算入の上限・対象の区分)が「…」の中(rest)に落ちてはいけない。
  test 'rule_field_groups は、必要単位を以上に、算入の上限を以下に、区分を対象に振り分ける' do
    groups = rule_field_groups({ 'type' => 'credit_sum' })

    assert groups[:lower]
    assert_not groups[:upper]
    assert_equal %w[categories], groups[:target].map(&:first)
    assert_equal %w[label detail], groups[:rest].map(&:first)
    assert_empty groups[:nested]
  end

  test 'rule_field_groups は、算入上限の credits を以下の欄にする' do
    groups = rule_field_groups({ 'type' => 'cap' })

    assert_not groups[:lower]
    assert groups[:upper]
    assert_equal %w[category], groups[:target].map(&:first)
    assert_not_includes groups[:rest].map(&:first), 'credits'
  end

  test 'rule_field_groups は、経路・選択肢・条件を入れ子に回す(1つの欄では直せない)' do
    assert_equal %w[paths], rule_field_groups({ 'type' => 'one_of_paths' })[:nested].map(&:first)
    assert_equal %w[options], rule_field_groups({ 'type' => 'any_of' })[:nested].map(&:first)
    assert_equal %w[conditions], rule_field_groups({ 'type' => 'all_of' })[:nested].map(&:first)
  end

  test 'rule_field_groups は、どの型でも判定の数字を決める欄を「…」の中に落とさない' do
    judging = %w[required_credits credits categories category required_categories]
    CurriculumImport::Validation::Input::TOP_LEVEL.each do |type|
      rest = rule_field_groups({ 'type' => type })[:rest].map(&:first)
      assert_empty rest & judging, "#{type} の #{(rest & judging).join('・')} が「…」の中にあります"
    end
  end

  # 必要単位(下限)も、代わりに出す言葉も無い行だけ「内数」と出す。文書には書き込まない(設計書 項目3)。
  test 'inner_row? は、必要単位も表示の言葉も無い行だけ true' do
    assert inner_row?({ 'required_credits' => nil, 'required_label' => nil })
    assert_not inner_row?({ 'required_credits' => 4, 'required_label' => nil })
    assert_not inner_row?({ 'required_credits' => nil, 'required_label' => '内数22単位枠' })
  end

  # 読むだけの枠には name を付けない。名前の無い欄はブラウザも送らないので、
  # 「触らずに保存したとき、文書が1バイトも変わらない」を壊さない。
  test 'credit_range は、読むだけの枠に name を付けない' do
    markup = Nokogiri::HTML5.fragment(credit_range(['row[required_credits]', 4], 2))

    assert_equal ['row[required_credits]'], markup.css('input').pluck('name')
    assert_match(/2/, markup.css('span').map(&:text).join)
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

