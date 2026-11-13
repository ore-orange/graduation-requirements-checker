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

  # ---- グループの分け方(設計書 項目3-3) ----
  #
  # いままでは group_by に field:language / number_prefix を手で打たせ、呼び名を別の欄で打たせていた。
  # 画面に内部の語彙を出さないため、決まった選択肢にする。

  test 'グループの分け方は、提供コースと言語の選択肢で出る' do
    options = group_by_options('number_prefix')

    assert_equal %w[number_prefix field:language], options.map(&:last)
    assert_equal ['提供コース(科目番号の先頭)', '言語'], options.map(&:first)
  end

  # この画面は未知の便覧を読むための画面。RuleShape は number_prefix_hundreds や field:<任意の欄> も通す。
  # 2択に絞ると、別の便覧でAIがそう読んだ決まりが、画面を開いて保存しただけで書き換わってしまう。
  test '2択に無い値は、いまの設定として選択肢に残る' do
    options = group_by_options('field:credits')

    assert_includes options, ['いまの設定: field:credits', 'field:credits']
  end

  test '2択のどちらかなら、いまの設定は足さない' do
    options = group_by_options('field:language')

    assert_equal 2, options.size
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

