# frozen_string_literal: true

require 'test_helper'
require_relative '../../../support/requirements_draft_fixtures'

# 決まりが「持ち主(行・章・枠・総単位の枠)と同じことを言っているか」の判定(設計書 項目1)。
#
# 2024年度の実データでは、27個の決まりのうち12個が、上の行・章・枠と文字通り同じ(同じ必要単位・同じ区分)。
# 同じことを二度書いている箱を画面から消すための判定を、ここ1か所で決める。画面(どの箱を出すか)と
# 保存(どの決まりに書き戻すか)が、同じ判定を引く。食い違うと、隠した箱の値を誰も書かない穴ができる。
#
# 判定は必ず安全側(箱を出す側)に倒す。隠してよいのは、同じ値が持ち主にそのまま出ているときだけ。
class RequirementsReviewMirrorTest < ActiveSupport::TestCase
  include RequirementsDraftFixtures

  Mirror = CurriculumImport::RequirementsReview::Mirror

  def mirror(document = requirements_document)
    Mirror.new(CurriculumImport::Validation::Input.new(document, []))
  end

  def rule_named(document, id) = document['rules'].find { |rule| rule['id'] == id }

  def group_named(document, id) = document['display']['groups'].find { |group| group['id'] == id }

  def row_named(document, id)
    document['display']['groups'].flat_map { |group| group['rows'].to_a }.find { |row| row['id'] == id }
  end

  # ---- 行 ----

  test '行と同じ必要単位・同じ区分の credit_sum は、同じことを言っている' do
    document = requirements_document

    assert mirror(document).duplicate?(rule_named(document, 'humanities'), :row, row_named(document, 'humanities'))
  end

  test '必要単位が食い違う credit_sum は、同じことを言っていない' do
    document = requirements_document
    rule_named(document, 'humanities')['required_credits'] = 6

    assert_not mirror(document).duplicate?(rule_named(document, 'humanities'), :row, row_named(document, 'humanities'))
  end

  test '区分が食い違う credit_sum は、同じことを言っていない' do
    document = requirements_document
    rule_named(document, 'humanities')['categories'] = %w[humanities english]

    assert_not mirror(document).duplicate?(rule_named(document, 'humanities'), :row, row_named(document, 'humanities'))
  end

  test '区分の並び順が違っても、集合が同じなら同じことを言っている' do
    document = requirements_document
    row = row_named(document, 'humanities')
    row['categories'] = %w[english humanities]
    rule = rule_named(document, 'humanities')
    rule['categories'] = %w[humanities english]

    assert mirror(document).duplicate?(rule, :row, row)
  end

  # 2 と 2.0 は同じ単位。文字どおりの一致で見ると、読み取りの書き方の違いで箱が出たり消えたりする。
  test '整数と小数で書かれた同じ単位は、同じことを言っている' do
    document = requirements_document
    rule_named(document, 'humanities')['required_credits'] = 4.0

    assert mirror(document).duplicate?(rule_named(document, 'humanities'), :row, row_named(document, 'humanities'))
  end

  test 'credit_sum でない決まりは、同じことを言っていない' do
    document = requirements_document
    row = row_named(document, 'required_core')

    %w[path_rule core fusion_provider excluded_category].each do |id|
      assert_not mirror(document).duplicate?(rule_named(document, id), :row, row), "#{id} を隠してはいけない"
    end
  end

  # ---- 章・枠 ----

  test '章は、中の行の区分の合併と比べる' do
    document = requirements_document
    group = group_named(document, 'common') # 必要単位6、中の行は humanities と english
    rule = fixture_rule('common_total', 'credit_sum', categories: %w[humanities english], required_credits: 6)

    assert mirror(document).duplicate?(rule, :group, group)
  end

  test '章の決まりの区分が、中の行の合併と食い違えば、同じことを言っていない' do
    document = requirements_document
    group = group_named(document, 'common')
    rule = fixture_rule('common_total', 'credit_sum', categories: ['humanities'], required_credits: 6)

    assert_not mirror(document).duplicate?(rule, :group, group)
  end

  test '枠は、囲んでいる行の区分の合併と比べる' do
    document = requirements_document
    frame = CurriculumImport::RequirementsReview::Tree::Frame.new(
      subtotal: { 'id' => 'sub', 'name' => '合計', 'required_credits' => 6 },
      rows: [row_named(document, 'humanities'), row_named(document, 'english')], index: 0, row_index: 0
    )
    rule = fixture_rule('sub', 'credit_sum', categories: %w[humanities english], required_credits: 6)

    assert mirror(document).duplicate?(rule, :frame, frame)
  end

  # ---- 総単位の枠 ----

  test '総単位は、卒業の総単位に数える区分すべてと比べる' do
    document = requirements_document # total_credits 14、数える区分は excluded 以外の4つ

    assert mirror(document).duplicate?(rule_named(document, 'total'), :total, nil)
  end

  test '総単位の決まりに、数えない区分が混ざっていれば、同じことを言っていない' do
    document = requirements_document
    rule_named(document, 'total')['categories'] += ['excluded']

    assert_not mirror(document).duplicate?(rule_named(document, 'total'), :total, nil)
  end

  # ---- 安全側に倒す ----

  # 箱を隠すと、その決まりに付いた指摘を出す場所も消える。上のまとめには id だけが残り、
  # 画面のどこからもその id を辿れなくなる(目標「内部の語彙を画面に出さない」と噛み合わない)。
  test '指摘が付いている決まりは、同じことを言っていても隠さない' do
    document = requirements_document

    assert_not mirror(document).duplicate?(rule_named(document, 'humanities'), :row,
                                           row_named(document, 'humanities'), blocked: true)
  end

  # ---- 持ち主が数える区分 ----

  test '持ち主が数える区分を、行・章・枠・総単位で引ける' do
    document = requirements_document
    subject = mirror(document)

    assert_equal ['humanities'], subject.counted_categories(:row, row_named(document, 'humanities'))
    assert_equal %w[humanities english].sort,
                 subject.counted_categories(:group, group_named(document, 'common')).sort
    assert_equal %w[humanities english required_core fusion].sort,
                 subject.counted_categories(:total, nil).sort
  end
end

