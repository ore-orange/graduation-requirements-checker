# frozen_string_literal: true

require 'test_helper'
require_relative '../../../support/requirements_draft_fixtures'

# 規則の中でも、1つの欄では直せなかったもの(経路・選択肢・条件)を、画面の欄から直す。
# ここが JSON でしか直せないと、判定の数字を決める値が、人が開かない畳まれた文字列の中に残る。
class RuleEditingTest < ActiveSupport::TestCase
  include RequirementsDraftFixtures

  setup do
    @curriculum = Curriculum.create!(slug: 'rule_editing', admission_year: 2025, faculty_name: '工学部',
                                     department_name: '工学科 知能情報コース', source_filename: 'handbook.pdf',
                                     pages: [], document: editable_document)
  end

  # fixture の規則に、経路(one_of_paths)と選択肢(any_of)を持つものを足した文書。
  def editable_document
    document = requirements_document
    document['rules'] = document['rules'] + [
      fixture_rule('english_required', 'one_of_paths', paths: [%w[role_a]]),
      fixture_rule('some_any_of', 'any_of',
                   options: [{ 'type' => 'credit_sum', 'categories' => %w[humanities], 'required_credits' => 2 }])
    ]
    document
  end

  def edit(**params)
    revision = CurriculumImport::RequirementsEdit.revision(@curriculum.document)
    CurriculumImport::RequirementsEdit.new(@curriculum, { revision: revision }.merge(params)).call
  end

  def document_after = @curriculum.reload.document

  def rule_after(id) = document_after['rules'].find { |rule| rule['id'] == id }

  # 画面が送るのは科目の key。役割キーはアプリが裏で振る(設計書 項目3-1)。
  test '経路を科目の選択から直す(JSONを使わない)' do
    result = edit(rules: { '0' => { id: 'english_required',
                                    paths: { 'a' => { roles: %w[course_外101] },
                                             'b' => { roles: %w[course_外102] } } } })

    assert result.ok?, result.errors.join('/')
    assert_equal [['course_外101'], ['course_外102']], rule_after('english_required')['paths']
  end

  test '1つの経路に役割を2つ以上置ける(両方そろって1つの経路)' do
    edit(rules: { '0' => { id: 'english_required', paths: { 'a' => { roles: %w[role_a role_b] } } } })

    assert_equal [%w[role_a role_b]], rule_after('english_required')['paths']
  end

  test '役割を1つも選ばなかった経路は捨てる(空の経路は、何も求めない経路になってしまう)' do
    edit(rules: { '0' => { id: 'english_required',
                           paths: { 'a' => { roles: %w[role_a] }, 'b' => { roles: [''] } } } })

    assert_equal [%w[role_a]], rule_after('english_required')['paths']
  end

  # ---- グループの分け方(設計書 項目3-3) ----

  # 呼び名(group_label)は学生の画面に「同一の◯◯から」と出る値。画面の欄をやめ、分け方から決めて書く。
  test 'グループの分け方を選び直すと、呼び名も合わせて書く' do
    edit(rules: { '0' => { id: 'fusion_provider', group_by: 'field:language' } })

    assert_equal 'field:language', rule_after('fusion_provider')['group_by']
    assert_equal '言語', rule_after('fusion_provider')['group_label']
  end

  # AI が「開講コース」など別の呼び名で読んだ値を、画面を開いて保存しただけで上書きしない。
  test '分け方を触らない保存では、呼び名を上書きしない' do
    document = @curriculum.document.deep_dup
    document['rules'].find { |rule| rule['id'] == 'fusion_provider' }['group_label'] = '開講コース'
    @curriculum.update!(document: document)

    edit(rules: { '0' => { id: 'fusion_provider', group_by: 'number_prefix' } })

    assert_equal '開講コース', rule_after('fusion_provider')['group_label']
  end

  # 画面は呼び名を隠し欄で送り返すので、もともと呼び名が無い決まりは空で返ってくる。
  # それを「選び直された」と読むと、触っていない決まりに呼び名が書かれ、人が確認した印まで付く。
  # 印が付くと、そのページを読み直しても判定の数字を直せなくなる(英語12 / 英語8＋同一言語4 など)。
  test '呼び名の無い入れ子の決まりは、触らずに保存しても変わらない' do
    document = @curriculum.document.deep_dup
    rule = document['rules'].find { |item| item['id'] == 'some_any_of' }
    rule['options'] = [{ 'type' => 'grouped_max', 'category' => 'fusion', 'group_by' => 'number_prefix',
                         'required_credits' => 4 }]
    @curriculum.update!(document: document)
    before = @curriculum.document.deep_dup

    result = edit(rules: { '0' => { id: 'some_any_of',
                                    options: { 'a' => { type: 'grouped_max', category: 'fusion',
                                                        group_by: 'number_prefix', group_label: '',
                                                        required_credits: '4' } } } })

    assert_predicate result, :ok?
    assert_equal before, document_after
  end

  test '経路を直した規則には、読み直しから守る印が付く' do
    edit(rules: { '0' => { id: 'english_required', paths: { 'a' => { roles: %w[role_b] } } } })

    assert_equal true, rule_after('english_required')[CurriculumImport::DraftMerge::CONFIRMED]
  end

  test '同じ経路を送り返しても、直したことにはならない' do
    result = edit(rules: { '0' => { id: 'english_required', paths: { 'a' => { roles: %w[role_a] } } } })

    assert result.ok?
    assert_nil rule_after('english_required')[CurriculumImport::DraftMerge::CONFIRMED]
  end

  test 'any_ofの選択肢をJSONを使わず直す' do
    edit(rules: { '0' => { id: 'some_any_of',
                           options: { 'a' => { type: 'credit_sum', categories: %w[humanities],
                                               required_credits: '4' },
                                      'b' => { type: 'grouped_max', category: 'fusion',
                                               group_by: 'number_prefix', required_credits: '4' } } } })

    assert_equal [{ 'type' => 'credit_sum', 'categories' => %w[humanities], 'required_credits' => 4 },
                  # 呼び名は書かない。学生の画面は、分け方から日本語を作る(RuleSentenceHelper::GROUP_BY_NAMES)。
                  # 送られた値を読むだけにしておかないと、呼び名の無い決まりが保存のたびに書き換わる。
                  { 'type' => 'grouped_max', 'category' => 'fusion', 'group_by' => 'number_prefix',
                    'required_credits' => 4 }],
                 rule_after('some_any_of')['options']
  end

  test 'any_ofの選択肢には all_of を置ける(その中の条件も欄から直す)' do
    edit(rules: { '0' => { id: 'some_any_of',
                           options: { 'a' => { type: 'all_of',
                                               conditions: { 'x' => { type: 'credit_sum', categories: %w[english],
                                                                      required_credits: '8' } } } } } })

    assert_equal [{ 'type' => 'all_of',
                    'conditions' => [{ 'type' => 'credit_sum', 'categories' => %w[english],
                                       'required_credits' => 8 }] }],
                 rule_after('some_any_of')['options']
  end

  test 'all_ofの中にall_ofは置けない(その条件は捨てて指摘する)' do
    result = edit(rules: { '0' => { id: 'some_any_of',
                                    options: { 'a' => { type: 'all_of',
                                                        conditions: { 'x' => { type: 'all_of' } } } } } })

    assert_not result.ok?
    assert_match(/all_of/, result.errors.join)
    assert_equal requirements_document['rules'].size + 2, document_after['rules'].size, '何も保存しない'
  end

  test '知らない型の条件は受けない' do
    result = edit(rules: { '0' => { id: 'some_any_of', options: { 'a' => { type: 'one_of_paths' } } } })

    assert_not result.ok?
  end

  # ---- 規則を足す(JSON でも id でもなく、型と欄から) ----
  # 人は規則の id を一度も打たない。id はアプリが裏で振る(設計書 項目5)。

  test '新しい規則をJSONを使わず型と欄から足す。id は自動で付く' do
    result = edit(new_rule: { type: 'credit_sum', label: '追加分',
                              categories: %w[humanities], required_credits: '2' })

    assert result.ok?, result.errors.join('/')
    rule = rule_after('added_rule_1')
    assert_equal 'credit_sum', rule['type']
    assert_equal %w[humanities], rule['categories']
    assert_equal 2, rule['required_credits']
    assert_equal '追加分', rule['label']
    assert_equal true, rule[CurriculumImport::DraftMerge::CONFIRMED]
  end

  test '足す規則の経路も、欄から組む' do
    edit(new_rule: { type: 'one_of_paths', label: '足した経路',
                     paths: { 'a' => { roles: %w[role_a] }, 'b' => { roles: %w[role_b] } } })

    assert_equal [%w[role_a], %w[role_b]], rule_after('added_rule_1')['paths']
  end

  test '足す規則の選択肢も、欄から組む' do
    edit(new_rule: { type: 'any_of', label: '足した選択',
                     options: { 'a' => { type: 'credit_sum', categories: %w[english], required_credits: '2' } } })

    assert_equal [{ 'type' => 'credit_sum', 'categories' => %w[english], 'required_credits' => 2 }],
                 rule_after('added_rule_1')['options']
  end

  # 結びつける先を選ぶと、id はその行・章・枠の id から作る(<行の id>_c1)。
  test '足す規則の id は、結びつける先の id から作る' do
    result = edit(new_rule: { type: 'credit_sum', label: '追加分', link: 'row:humanities',
                              categories: %w[humanities], required_credits: '2' })

    assert result.ok?, result.errors.join('/')
    assert_equal 'credit_sum', rule_after('humanities_c1')['type']
  end

  # 自動で振る id が既にあるときは、重ならない番号まで進める。
  test '規則を続けて足すと、id の番号が進む' do
    edit(new_rule: { type: 'credit_sum', label: 'さき', categories: %w[english], required_credits: '2' })
    result = edit(new_rule: { type: 'credit_sum', label: 'あと', categories: %w[humanities], required_credits: '2' })

    assert result.ok?, result.errors.join('/')
    assert_equal 'さき', rule_after('added_rule_1')['label']
    assert_equal 'あと', rule_after('added_rule_2')['label']
  end

  test '足す規則の型が空なら、何も足さない(画面は空の組を毎回送る)' do
    before = document_after['rules'].size
    result = edit(new_rule: { type: '', label: '' })

    assert result.ok?
    assert_equal before, document_after['rules'].size
  end

  test '足す規則の型が知らないものなら断る' do
    result = edit(new_rule: { type: 'nonsense', label: 'あやしい' })

    assert_not result.ok?
  end

  test '規則の JSON の欄は無くなった(欄から直す)' do
    result = edit(rules: { '0' => { id: 'humanities', json: '{"id":"humanities","type":"credit_sum"}' } })

    assert result.ok?, result.errors.join('/')
    assert_equal %w[humanities], rule_after('humanities')['categories'], 'json は読まない'
  end

  # ---- 入れ子の条件の、順番と空の扱い ----

  # 区分のチェックは、便覧の区分の並びで送り返される。規則に書かれた並びと違っても、同じ区分なら直したことにしない
  # (そうしないと、触っていない規則に確認済みの印が付き、読み直しで AI の読みを受け取れなくなる)。
  test '入れ子の条件の区分は、並びが違うだけなら直したことにしない' do
    @curriculum.update!(document: @curriculum.document.deep_dup.tap do |doc|
      doc['rules'].find { |r| r['id'] == 'some_any_of' }['options'] =
        [{ 'type' => 'credit_sum', 'categories' => %w[english humanities], 'required_credits' => 2 }]
    end)

    result = edit(rules: { '0' => { id: 'some_any_of',
                                    options: { 'a' => { type: 'credit_sum', categories: %w[humanities english],
                                                        required_credits: '2' } } } })

    assert result.ok?, result.errors.join('/')
    assert_nil rule_after('some_any_of')[CurriculumImport::DraftMerge::CONFIRMED]
    assert_equal %w[english humanities], rule_after('some_any_of')['options'][0]['categories'], '並びも変えない'
  end

  # all_of は、中の条件がまだ無くても1つの選択肢として残す(空だから捨てると、画面から all_of を作れない)。
  # 条件が無いことは、突き合わせ(RuleShape)が指摘する。
  test '中身がまだ無い all_of の選択肢も、捨てずに残す' do
    edit(rules: { '0' => { id: 'some_any_of',
                           options: { 'a' => { type: 'credit_sum', categories: %w[english],
                                               required_credits: '2' },
                                      'b' => { type: 'all_of' } } } })

    assert_equal %w[credit_sum all_of], rule_after('some_any_of')['options'].pluck('type')
  end

  # ---- 規則を足すフォームの欄は、種類ごとに分ける ----

  # 画面は種類ごとの欄を全部出す(JavaScript が動かないときも書けるように)。同じ名前で出すと、
  # 選んだ種類の値を、別の種類の空欄が後から上書きしてしまう。
  test '足す規則の欄は種類ごとに分かれていて、別の種類の空欄に消されない' do
    result = edit(new_rule: { type: 'credit_sum', label: '追加',
                              fields: { 'credit_sum' => { categories: %w[humanities], required_credits: '2' },
                                        'grouped_max' => { category: '', group_by: '', required_credits: '' },
                                        'all_required' => { required_credits: '', expected_course_count: '' } } })

    assert result.ok?, result.errors.join('/')
    assert_equal 2, rule_after('added_rule_1')['required_credits']
    assert_equal %w[humanities], rule_after('added_rule_1')['categories']
  end

  # ---- 要確認の文面も欄から直す ----

  test 'one_of_paths の要確認の文面を欄から直せる' do
    edit(rules: { '0' => { id: 'english_required', review_note: '系列が重複しているので確認が要る' } })

    assert_equal '系列が重複しているので確認が要る', rule_after('english_required')['review_note']
  end
end

