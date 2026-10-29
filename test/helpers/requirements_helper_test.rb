# frozen_string_literal: true

require 'test_helper'

# 便覧の規則を一文にする。実物の便覧に加えて、合成した便覧で型ごとの書き分けと、読めない規則の扱いを見る。
class RequirementsHelperTest < ActionView::TestCase
  setup do
    @real = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    @handbook = {
      'categories' => [{ 'key' => 'a', 'label' => '甲群' }, { 'key' => 'b', 'label' => '乙群' }],
      'courses' => [{ 'key' => 'k1', 'name' => '科目一', 'roles' => ['r1'] },
                    { 'key' => 'k2', 'name' => '科目二', 'roles' => ['r2'] },
                    { 'key' => 'k3', 'name' => '科目三', 'roles' => %w[r2 r3] }]
    }
  end

  # Capybara.string は表示を持たないので、タグの境目を空白にして、ブラウザで見たときの区切りを文字に残す。
  def rule_html(definition, curriculum = @handbook)
    Capybara.string(rule_entry(definition, curriculum).gsub('><', '> <'))
  end

  # 型の見出し（バッジ）を除いた、規則の文面。
  def rule_text(definition, curriculum = @handbook)
    html = rule_html(definition, curriculum)
    html.text.squish.delete_prefix(html.all('[data-rule-kind]').first&.text.to_s).strip
  end

  def real_rule(id) = @real.fetch('rules').find { |rule| rule['id'] == id }
  def real_text(id) = rule_text(real_rule(id), @real)

  test 'credit_sum は区分の和名と必要単位を一文にする' do
    text = rule_text('id' => 'x', 'type' => 'credit_sum', 'label' => '合計', 'categories' => %w[a b],
                     'required_credits' => 12)

    assert_equal '合計：甲群・乙群の合計 12単位以上', text
  end

  test '単位は小数も整数も余計な桁を付けずに出す' do
    assert_includes rule_text('type' => 'credit_sum', 'label' => 'L', 'categories' => ['a'], 'required_credits' => 1.5),
                    '1.5単位以上'
    assert_includes rule_text('type' => 'credit_sum', 'label' => 'L', 'categories' => ['a'], 'required_credits' => 2.0),
                    ' 2単位以上'
  end

  test '区分が便覧に無ければキーのまま出す' do
    assert_includes rule_text('type' => 'credit_sum', 'label' => 'L', 'categories' => ['zzz'], 'required_credits' => 2),
                    'zzzの合計'
  end

  test 'any_of は選択肢を、または でつないだ候補として並べる' do
    html = rule_html({ 'id' => 'x', 'type' => 'any_of', 'label' => '経路',
                       'options' => [{ 'type' => 'credit_sum', 'categories' => ['a'], 'required_credits' => 12 },
                                     { 'type' => 'all_of',
                                       'conditions' => [{ 'type' => 'credit_sum', 'categories' => ['a'],
                                                          'required_credits' => 8 },
                                                        { 'type' => 'grouped_max', 'category' => 'b',
                                                          'group_by' => 'field:language', 'group_label' => '言語',
                                                          'required_credits' => 4 }] }] })

    assert_includes html.text.squish, '経路：次のいずれかを満たす'
    assert_includes html.text.squish, '甲群の合計 12単位以上 または 次をすべて満たす'
    assert_includes html.text.squish, 'または 次をすべて満たす'
    assert_includes html.text.squish, '甲群の合計 8単位以上 かつ 乙群のうち、同一の言語から 4単位以上'
  end

  test 'one_of_paths は系列を科目名で出し、系列どうしは または でつなぐ' do
    text = rule_text('id' => 'x', 'type' => 'one_of_paths', 'label' => '系列', 'paths' => [%w[r1 r2], ['r3']])

    assert_includes text, '系列：次のいずれかの系列を修得する'
    assert_includes text, '科目一 ＋ 科目二／科目三'
    assert_includes text, 'または 科目三'
  end

  test 'one_of_paths の系列が1つだけなら、いずれか とは書かない' do
    text = rule_text('id' => 'x', 'type' => 'one_of_paths', 'label' => '系列', 'paths' => [['r1']])

    assert_equal '系列：次を修得する：科目一', text
  end

  test '科目表に無い役割は、そのことが分かる形で出す' do
    assert_includes rule_text('type' => 'one_of_paths', 'label' => '系列', 'paths' => [['nothing']]),
                    'nothing（科目表に該当なし）'
  end

  test 'grouped_max は同一のグループから必要単位を求める文にする' do
    text = rule_text('type' => 'grouped_max', 'label' => '提供', 'category' => 'a', 'group_by' => 'number_prefix',
                     'required_credits' => 4)

    assert_equal '提供：甲群のうち、同一の科目番号の接頭辞から 4単位以上', text
  end

  test 'grouped_max は group_label が無ければ欄の名前を使う' do
    text = rule_text('type' => 'grouped_max', 'label' => '言語', 'category' => 'a', 'group_by' => 'field:language',
                     'required_credits' => 4)

    assert_equal '言語：甲群のうち、同一のlanguageから 4単位以上', text
  end

  test 'all_required は科目数と区分を出す' do
    text = rule_text('type' => 'all_required', 'label' => '必修すべて', 'expected_course_count' => 31,
                     'required_credits' => 57, 'required_categories' => %w[a b])

    assert_equal '必修すべて：甲群・乙群の必修科目 31科目（計 57単位）をすべて修得', text
  end

  test 'cap は区分の算入上限を出す' do
    assert_equal '甲群は卒業算入の上限 2単位', rule_text('id' => 'c', 'type' => 'cap', 'category' => 'a', 'credits' => 2)
  end

  test 'exclude は理由を添え、number_prefix があれば範囲を絞る' do
    assert_equal '甲群は卒業単位に算入しない：対象外',
                 rule_text('type' => 'exclude', 'category' => 'a', 'reason' => '対象外')
    assert_equal '甲群のうち科目番号が「知能」で始まる科目は卒業単位に算入しない：自コース',
                 rule_text('type' => 'exclude', 'category' => 'a', 'number_prefix' => '知能', 'reason' => '自コース')
  end

  test '出典と注記があれば添える' do
    text = rule_text('type' => 'credit_sum', 'label' => 'L', 'categories' => ['a'], 'required_credits' => 2,
                     'source_page' => '便覧3ページ', 'detail' => '合計です。')

    assert_includes text, '備考：合計です。'
    assert_includes text, '出典：便覧3ページ'
    assert_not_includes rule_text('type' => 'credit_sum', 'label' => 'L', 'categories' => ['a'],
                                  'required_credits' => 2), '出典'
  end

  test '未知の型は赤で、解釈できないと出し、id とラベルで探せる' do
    html = rule_html('id' => 'gpa', 'type' => 'gpa', 'label' => 'GPA')

    assert_includes html.text, '規則の型「gpa」をこのアプリは解釈できません'
    assert_includes html.text, 'gpa'
    assert_includes html.text, 'GPA'
    assert html.has_css?('li[data-rule-status="unknown"] .text-red-700')
  end

  test '型のない規則も、ハッシュでない規則も、落とさず赤で出す' do
    [{ 'id' => 'noType' }, 'text', nil, 3].each do |rule|
      html = rule_html(rule)

      assert html.has_css?('li[data-rule-status="unknown"] .text-red-700'), rule.inspect
      assert_includes html.text, '解釈できません'
    end
  end

  test '入れ子で置けない位置の規則は、その選択肢だけ赤で出す' do
    html = rule_html('id' => 'x', 'type' => 'any_of', 'label' => '経路',
                     'options' => [{ 'type' => 'credit_sum', 'categories' => ['a'], 'required_credits' => 2 },
                                   { 'type' => 'one_of_paths', 'paths' => [['r1']] }])

    assert_equal 1, html.all('ul .text-red-700').size
    assert_includes html.find('ul .text-red-700').text, 'この位置には置けません'
    assert_includes html.text, '甲群の合計 2単位以上'
  end

  test '入れ子の奥に読めない選択肢があれば、規則の側も赤で知らせ、id とラベルで探せる' do
    html = rule_html('id' => 'route', 'type' => 'any_of', 'label' => '経路',
                     'options' => [{ 'type' => 'credit_sum', 'categories' => ['a'], 'required_credits' => 2 },
                                   { 'type' => 'gpa' }])

    assert html.has_css?('li[data-rule-id="route"][data-rule-status="unknown"]')
    notice = html.all('div.text-red-700').first
    assert_includes notice.text, 'この規則には、このアプリが解釈できない部分があります'
    assert_includes notice.text, '判定では充足とせず、要確認になります'
    assert_includes notice.text, 'id: route／経路'
  end

  test 'all_of の中の読めない条件も、一番上の規則まで知らせる' do
    html = rule_html('id' => 'route', 'type' => 'any_of', 'label' => '経路',
                     'options' => [{ 'type' => 'all_of', 'conditions' => [{ 'type' => 'gpa' }] }])

    assert html.has_css?('li[data-rule-status="unknown"]')
    assert html.has_css?('div.text-red-700', text: '要確認になります')
  end

  test '読める規則だけなら赤い知らせは出ない' do
    html = rule_html('id' => 'x', 'type' => 'credit_sum', 'label' => 'L', 'categories' => ['a'],
                     'required_credits' => 2)

    assert_not html.has_css?('.text-red-700')
    assert_not html.has_css?('[data-rule-status]')
  end

  test '選択肢が空の any_of は、何も主張しないので赤で出す' do
    html = rule_html('id' => 'route', 'type' => 'any_of', 'label' => '経路', 'options' => [])

    assert html.has_css?('li[data-rule-status="unknown"]')
    assert html.has_css?('ul .text-red-700', text: '選択肢が空です')
  end

  test '条件が空の all_of も赤で出し、一番上の any_of まで知らせる' do
    html = rule_html('id' => 'route', 'type' => 'any_of', 'label' => '経路',
                     'options' => [{ 'type' => 'all_of', 'conditions' => [] }])

    assert html.has_css?('li[data-rule-status="unknown"]')
    assert html.has_css?('ul .text-red-700', text: '条件が空です')
  end

  test '系列が1つも無い one_of_paths は赤で出す' do
    [[], [[]], nil].each do |paths|
      html = rule_html('id' => 'p', 'type' => 'one_of_paths', 'label' => '系列', 'paths' => paths)

      assert html.has_css?('li[data-rule-status="unknown"]'), paths.inspect
      assert html.has_css?('ul .text-red-700', text: '系列が空です'), paths.inspect
    end
  end

  test '空の系列が混ざっていれば、その系列だけ赤で出す' do
    html = rule_html('id' => 'p', 'type' => 'one_of_paths', 'label' => '系列', 'paths' => [['r1'], []])

    assert_equal ['系列が空です'], html.all('ul .text-red-700').map(&:text)
    assert_includes html.text, '科目一'
    assert html.has_css?('li[data-rule-status="unknown"]')
  end

  test 'review_note は「系列が混在したとき」として出す' do
    text = rule_text('type' => 'one_of_paths', 'label' => '系列', 'paths' => [['r1']], 'review_note' => '重複を確認する')

    assert_includes text, '系列が混在したとき：重複を確認する'
  end

  test '実物: calculus の review_note' do
    assert_includes real_text('calculus'), '系列が混在したとき：微分積分学の系列が混在・重複しており'
  end

  test 'any_of の中の cap も置けない位置として赤で出す' do
    html = rule_html('type' => 'any_of', 'label' => '経路',
                     'options' => [{ 'type' => 'cap', 'category' => 'a', 'credits' => 2 }])

    assert html.has_css?('.text-red-700')
  end

  test '便覧の文字列は escape される' do
    html = rule_html('type' => 'credit_sum', 'label' => '<b>x</b>', 'categories' => ['a'], 'required_credits' => 2,
                     'source_page' => '<script>alert(1)</script>')

    assert_not html.has_css?('b')
    assert_not html.has_css?('script')
    assert_includes html.text, '<b>x</b>'
  end

  test '実物: credit_sum' do
    assert_equal '健康運動系：健康運動系の合計 2単位以上 出典：docs/kogaku_chinot_y24.pdf（便覧10ページ・PDF11ページ）',
                 real_text('health')
  end

  test '実物: all_required' do
    assert_includes real_text('required_all'),
                    '専門必修31科目すべて：情報技術系（必修）・総合力演習（必修）・研究・基礎演習・実験（必修）・数学基礎（必修）・' \
                    '知能情報コア（必修）の必修科目 31科目（計 57単位）をすべて修得'
  end

  test '実物: one_of_paths' do
    assert_includes real_text('calculus'), '微分積分学の指定系列：次のいずれかの系列を修得する'
    assert_includes real_text('calculus'), '微分積分学ＳＴ（スタンダードコース）Ⅰ ＋ '
    assert_includes real_text('calculus'), 'または '
  end

  test '実物: any_of' do
    assert_includes real_text('foreign_language'), '外国語の選択経路：次のいずれかを満たす'
    assert_includes real_text('foreign_language'), '英語の合計 12単位以上'
    assert_includes real_text('foreign_language'), 'または 次をすべて満たす'
    assert_includes real_text('foreign_language'), 'かつ 英語以外の外国語のうち、同一の言語から 4単位以上'
  end

  test '実物: grouped_max' do
    assert_includes real_text('fusion_provider'), '同一の他コースが提供する工学融合：'
    assert_includes real_text('fusion_provider'), 'のうち、同一の科目番号の接頭辞から 4単位以上'
  end

  test '実物: cap と exclude' do
    assert_includes real_text('natural_cap'), '自然系は卒業算入の上限 2単位'
    assert_includes real_text('own_fusion'), '科目番号が「知能」で始まる科目は卒業単位に算入しない：自コース提供の工学融合科目は登録・算入不可'
  end

  test '実物の規則は1つも赤にならない' do
    @real.fetch('rules').each do |rule|
      html = rule_html(rule, @real)

      assert_not html.has_css?('.text-red-700'), rule['id']
      assert_not html.has_css?('[data-rule-status="unknown"]'), rule['id']
    end
  end
end

