# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require_relative '../support/requirements_draft_fixtures'

# 要件表の確認画面。AI が読んだ規則・区分・表示を人が見て直す、ただ1つの場所。
# 見せること(誤読が見える)と、直した値が読み直しから守られること(印が付く)を確かめる。
class CurriculaRequirementsReviewTest < ActionDispatch::IntegrationTest
  include RequirementsDraftFixtures

  ENV_LOCAL = { 'REMOTE_ADDR' => '127.0.0.1' }.freeze

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
  end

  teardown do
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
  end

  # 要件表のページ(2)を読み終えた下書き。そのページが足したものを contributed に持つ。
  def draft(document: requirements_document, extra_pages: [])
    contributed = { 'rules' => Array(document['rules']).grep(Hash).pluck('id'),
                    'groups' => document.dig('display', 'groups').grep(Hash).pluck('id'), 'subtotals' => [],
                    'total_credits' => true }
    pages = [{ 'page' => 1, 'kind' => 'skip', 'status' => 'pending', 'error' => nil, 'text' => '表紙' },
             { 'page' => 2, 'kind' => 'requirements', 'status' => 'read', 'error' => nil, 'text' => '要件',
               'contributed' => contributed }] + extra_pages
    Curriculum.create!(slug: 'x', admission_year: 2025, faculty_name: '工学部', department_name: '工学科 知能情報コース',
                       source_filename: 'handbook.pdf', pages: pages, document: document)
  end

  def show(draft) = get(curriculum_path(draft), env: ENV_LOCAL)

  def revision_of(draft) = CurriculumImport::RequirementsEdit.revision(draft.reload.document)

  def save(draft, with_revision: true, **params)
    params = params.merge(revision: revision_of(draft)) if with_revision
    patch update_rules_curriculum_path(draft), params: params, env: ENV_LOCAL
  end

  def groups(draft) = draft.reload.document['display']['groups']

  def group(draft, id) = groups(draft).find { |entry| entry['id'] == id }

  def rule(draft, id) = draft.reload.document['rules'].find { |entry| entry['id'] == id }

  # ---- 見せる ----

  test '区分ごとの必要単位の表が出る' do
    show(draft)

    assert_response :success
    assert_select 'tr', text: /1\. 共通教育 合計.*6/
    assert_select 'tr', text: /行humanities.*4/
    assert_select 'tr', text: /卒業に必要な総単位.*14/
    assert_select '#requirements_table th', text: /2\. 必修 合計/
  end

  test '行には、数える区分の名前と、確認する規則が出る' do
    show(draft)

    assert_select '#row-humanities', text: /人文系/
    assert_select '#row-fusion', text: /単位は確認する規則から取る/
    assert_select '#row-humanities a[href=?]', '#rule-humanities'
  end

  test '区分と規則の一覧が出て、総単位に数えない区分は赤で出る' do
    show(draft)

    assert_select '#requirements_categories li', count: 5
    assert_select '#category-excluded .text-rose-700', text: /総単位に数えない/
    assert_select '#requirements_rules li', count: 7
    assert_select '#rule-core', text: /必修の科目数: 2/
  end

  test '読み取った要件表が無い下書きは、確認するものが無いと言うだけで、突き合わせの結果を並べない' do
    unread = [{ 'page' => 1, 'kind' => 'skip', 'status' => 'pending' }]
    empty = Curriculum.create!(slug: 'y', admission_year: 2025, faculty_name: '工学部', department_name: 'コース',
                               source_filename: 'h.pdf', pages: unread)
    show(empty)

    assert_response :success
    assert_select '#requirements_review', text: /まだ要件表を読み取っていません/
    assert_select '#requirements_findings', count: 0
    assert_select '#requirements_form', count: 0
  end

  test '突き合わせの結果が画面に出る' do
    document = requirements_document
    document['display']['groups'][0]['rows'][0]['check_ids'] = %w[humanities vanished]
    show(draft(document: document))

    assert_select 'body', text: /規則が見つかりません/
    assert_select '#requirements_findings [data-blocking=true]', text: /vanished/
    assert_select '#requirements_findings', text: /公開を止める問題が1件/
    # 該当の行の下にも、同じ理由が出る
    assert_select '#row-humanities + tr', text: /規則が見つかりません: vanished/
    assert_select '#row-humanities a[href]', text: 'humanities'
    assert_select '#row-humanities .text-rose-700', text: /vanished.*規則が見つかりません/
  end

  test '問題が無ければ、機械の検査だけだと断ったうえで、問題なしと出す' do
    show(draft)

    assert_select '#requirements_findings', text: /見つかった問題はありません.*代わりにはなりません/
  end

  test '公開を止めない警告は、止めないと分かる色と言葉で出る' do
    document = requirements_document
    document['rules'] << fixture_rule('empty_paths', 'one_of_paths', paths: [])
    show(draft(document: document))

    assert_select '#requirements_findings', text: /公開は止まりませんが/
    assert_select '#requirements_findings [data-blocking=false]', text: /paths が空です/
    assert_select '#rule-empty_paths', text: /paths が空です/
  end

  test '判定に落とせない注釈は赤で出る' do
    document = requirements_document
    document['approval_notes'] = [{ 'scope' => 'category', 'category' => 'fusion', 'text' => '指導教員の承認が必要',
                                    'source_page' => 'PDF2ページ' }]
    show(draft(document: document))

    assert_select '.needs-attention', text: /指導教員の承認/
    assert_select '.needs-attention', text: /承認あり.*要確認/m
    assert_select '.needs-attention', text: /2科目/
  end

  test '科目に当てられなかった承認の注記は、ページの警告から赤いカードになる' do
    warning = CurriculumImport::ApprovalNotes.unresolved_warning('他学部の科目は指導教員の承認が必要')
    page = { 'page' => 5, 'kind' => 'requirements', 'status' => 'read', 'text' => '', 'warnings' => [warning] }
    show(draft(extra_pages: [page]))

    assert_select '.needs-attention[data-kind=approval_unattached]', text: /他学部の科目は指導教員の承認が必要/
    assert_select '.needs-attention', text: /承認なしで数えられます/
    assert_select 'select[name*="[category]"] option', text: '人文系'
  end

  test '外国人学生の特例らしい文は、判定の対象外と理由つきで赤く出る' do
    document = requirements_document
    document['rules'][0]['detail'] = '外国人留学生は日本語科目で読み替えられる。'
    show(draft(document: document))

    assert_select '.needs-attention[data-kind=foreign_student]', text: /外国人留学生は日本語科目/
    assert_select '.needs-attention', text: /判定の対象外/
  end

  test '要件表のページの文字にある外国人学生の文も拾う' do
    page = { 'page' => 6, 'kind' => 'requirements', 'status' => 'read', 'text' => '備考 私費外国人留学生の特例は別に定める。' }
    show(draft(extra_pages: [page]))

    assert_select '.needs-attention[data-kind=foreign_student]', text: /私費外国人留学生の特例/
  end

  test '注釈が1つも拾えなければ、拾えていないものもあると断る' do
    show(draft)

    assert_select '#annotation_cards', text: /拾えた注釈はありません/
    assert_select '#annotation_cards', text: /拾えていないものもあります/
  end

  test '保存のフォームは update_rules に向き、画面を開いた時点の指紋を持つ' do
    draft = draft()
    show(draft)

    assert_select 'form[action=?]', update_rules_curriculum_path(draft)
    assert_select 'form#requirements_form input[name=revision][value=?]', revision_of(draft)
  end

  test '人が直した項目には、人が確認した印が出る' do
    document = requirements_document
    document['rules'][0]['confirmed'] = true
    document['display']['groups'][0]['confirmed'] = true
    show(draft(document: document))

    assert_select '#rule-humanities', text: /人が確認した/
    assert_select '#group-common', text: /人が確認した/
    assert_select '#rule-english', text: /人が確認した/, count: 0
  end

  test '壊れた document でも、画面は開ける' do
    document = requirements_document
    document['display']['groups'][1]['rows'] = 'こわれた'
    document['rules'] = [1, document['rules'].first]
    show(draft(document: document))

    assert_response :success
    assert_select '#requirements_findings [data-blocking=true]'
  end

  test '公開済みの便覧には、開くことも保存することもできない' do
    published = Curriculum.create!(slug: 'z', admission_year: 2024, document: requirements_document,
                                   published_at: Time.current)
    get curriculum_path(published), env: ENV_LOCAL
    assert_redirected_to requirements_path

    patch update_rules_curriculum_path(published), params: { display: { total_credits: 1 } }, env: ENV_LOCAL
    assert_redirected_to requirements_path
    assert_equal 14, published.reload.document['display']['total_credits']
  end

  test 'ローカル以外からは保存できない' do
    draft = draft()
    patch update_rules_curriculum_path(draft), params: { display: { total_credits: 1 } },
                                               env: { 'REMOTE_ADDR' => '203.0.113.9' }

    assert_response :not_found
    assert_equal 14, draft.reload.document['display']['total_credits']
  end

  # ---- 直す ----

  test '章と行の並びを直せる' do
    draft = draft()
    save draft, display: { groups: [{ id: 'required', title: '1. 専門必修' }, { id: 'common', title: '2. 共通教育' },
                                    { id: 'elective' }] }

    assert_redirected_to curriculum_path(draft, anchor: 'requirements_review')
    assert_equal %w[required common elective], groups(draft).pluck('id')
    assert_equal '1. 専門必修', groups(draft).first['title']
    assert_equal '2. 共通教育', groups(draft).second['title']
  end

  test '章と行の並びは、フォームの並び(position)で直せる。直した並びの項目に印が付く' do
    draft = draft()
    rows = { '0' => { id: 'humanities', position: '2' }, '1' => { id: 'english', position: '1' } }
    save draft, display: { groups: {
      '0' => { id: 'common', position: '2', rows: rows },
      '1' => { id: 'required', position: '1' }, '2' => { id: 'elective', position: '3' }
    } }

    assert_equal %w[required common elective], groups(draft).pluck('id')
    assert_equal %w[english humanities], group(draft, 'common')['rows'].pluck('id')
    assert(group(draft, 'common')['rows'].all? { |row| row['confirmed'] })
    assert group(draft, 'required')['confirmed'], '位置が変わった章は、人が直したものとして印が付く'
    assert_nil group(draft, 'elective')['confirmed'], '位置の変わらなかった章に印は付かない'
  end

  test '直した項目だけに、人が確認した印が付く(触っていない項目には付けない)' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: '5' }, { id: 'english', required_credits: '2' }],
                display: { total_credits: '14', groups: [{ id: 'common', title: '1. 共通教育', required_credits: '6' }] }

    assert_equal 5, rule(draft, 'humanities')['required_credits']
    assert rule(draft, 'humanities')['confirmed']
    assert_nil rule(draft, 'english')['confirmed'], '同じ値を送り直しただけの規則に、印は付かない'
    assert_nil group(draft, 'common')['confirmed']
  end

  test '書式だけの違い(前後の空白・欄の有無)は、直したことにしない' do
    draft = draft()
    save draft, display: { groups: [{ id: 'common', title: " 1. 共通教育\r\n", rows: [{ id: 'humanities', subtitle: '',
                                                                                    credits_from_check: '0' }] }] },
                categories: [{ key: 'humanities', counts_toward_total: '1' }]

    assert_nil group(draft, 'common')['confirmed']
    assert_nil group(draft, 'common')['rows'].first['confirmed']
    assert_nil draft.document['categories'].first['confirmed']
    assert_match(/変えた箇所はありませんでした/, flash[:notice])
  end

  test '行の値を直すと、その行に印が付き、章ごと読み直しから守られる' do
    draft = draft()
    edited = { id: 'english', name: '英語(必修)', required_credits: '2.5', categories: ['english', ''],
               check_ids: 'english, humanities' }
    save draft, display: { groups: [{ id: 'common', rows: [edited] }] }

    row = group(draft, 'common')['rows'].find { |entry| entry['id'] == 'english' }
    assert_equal ['英語(必修)', 2.5, %w[english], %w[english humanities], true],
                 [row['name'], row['required_credits'], row['categories'], row['check_ids'], row['confirmed']]
    assert_nil group(draft, 'common')['rows'].find { |entry| entry['id'] == 'humanities' }['confirmed']
    assert CurriculumImport::DraftMerge::Withdrawal.human_edited?(group(draft, 'common'))
  end

  test '区分を直すと、その区分に印が付く' do
    draft = draft()
    save draft, categories: [{ key: 'excluded', label: '算入しない科目', counts_toward_total: '0' },
                             { key: 'fusion', counts_toward_total: '0' }]

    categories = draft.reload.document['categories']
    assert_equal '算入しない科目', categories.find { |c| c['key'] == 'excluded' }['label']
    assert categories.find { |c| c['key'] == 'excluded' }['confirmed']
    assert_equal false, categories.find { |c| c['key'] == 'fusion' }['counts_toward_total']
  end

  test '規則の欄を型ごとに直せる(必要単位・必修の科目数・区分)' do
    draft = draft()
    core = { id: 'core', expected_course_count: '3', required_categories: ['required_core', 'fusion', ''] }
    save draft, rules: [core,
                        { id: 'total', categories: %w[humanities english] },
                        { id: 'excluded_category', reason: '算入しない' }]

    assert_equal [3, %w[required_core fusion]],
                 rule(draft, 'core').values_at('expected_course_count', 'required_categories')
    assert_equal %w[humanities english], rule(draft, 'total')['categories']
    assert_equal '算入しない', rule(draft, 'excluded_category')['reason']
    assert(%w[core total excluded_category].all? { |id| rule(draft, id)['confirmed'] })
  end

  test '送られなかった項目は消えない(欠けた送信で規則や章が落ちない)' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', label: '人文' }], display: { groups: [{ id: 'common' }] }

    assert_equal 7, draft.reload.document['rules'].size
    assert_equal 3, groups(draft).size
  end

  test '消すと明示された規則・行・章・小計だけが消え、消したことが残る' do
    document = requirements_document
    document['display']['subtotals'] = [{ 'id' => 'sub', 'name' => '小計', 'required_credits' => 4,
                                          'row_ids' => ['fusion'], 'check_ids' => ['fusion_provider'] }]
    draft = draft(document: document)
    groups = [{ id: 'common', rows: [{ id: 'english', _destroy: '1' }] }, { id: 'elective', _destroy: '1' }]
    save draft, rules: [{ id: 'english', _destroy: '1' }],
                display: { groups: groups, subtotals: [{ id: 'sub', _destroy: '1' }] }

    document = draft.reload.document
    assert_not_includes document['rules'].pluck('id'), 'english'
    assert_equal %w[humanities], group(draft, 'common')['rows'].pluck('id')
    assert_nil group(draft, 'elective')
    assert_empty document['display']['subtotals']
    assert_equal([%w[rule english 2], %w[row english 2], %w[group elective 2], ['subtotal', 'sub', '']],
                 document['removed_by_human'].map { |entry| [entry['kind'], entry['id'], entry['page'].to_s] })
  end

  test '総単位を直すと、その値を足したページの記録から外れる(読み直しで消えない)' do
    draft = draft()
    save draft, display: { total_credits: '16' }

    assert_equal 16, draft.reload.document['display']['total_credits']
    assert_equal false, draft.pages.find { |page| page['page'] == 2 }['contributed']['total_credits']
  end

  test '数でない値は、何も保存せず、どの欄かを言う' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: 'たくさん' }], display: { total_credits: '16' }

    assert_match(/規則「humanities」の必要単位は数で入れてください/, flash[:alert])
    assert_equal 4, rule(draft, 'humanities')['required_credits']
    assert_equal 14, draft.document['display']['total_credits'], '一部だけ保存せず、全部を保存しない'
  end

  test '下書きに無い id を送ったら、何も保存せずに知らせる' do
    draft = draft()
    save draft, rules: [{ id: 'nothing', label: 'x' }]

    assert_match(/規則「nothing」は下書きにありません/, flash[:alert])
  end

  test '全角の数字と小数も数として読む' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: '４.５' }]

    assert_in_delta 4.5, rule(draft, 'humanities')['required_credits']
  end

  test '画面を開いたあとに中身が変わっていたら、何も変えない' do
    draft = draft()
    stale = revision_of(draft)
    late = fixture_rule('late', 'credit_sum', categories: ['english'], required_credits: 1)
    draft.update!(document: draft.document.merge('rules' => draft.document['rules'] + [late]))
    params = { revision: stale, rules: [{ id: 'humanities', required_credits: '9' }] }
    patch update_rules_curriculum_path(draft), params: params, env: ENV_LOCAL

    assert_match(/開いたあとに、要件表の中身が変わっています/, flash[:alert])
    assert_equal 4, rule(draft, 'humanities')['required_credits']
    assert_equal 8, draft.document['rules'].size
  end

  test '指紋を送らない保存は受ける(画面以外からの呼び出し)' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: '5' }], with_revision: false

    assert_equal 5, rule(draft, 'humanities')['required_credits']
  end

  test '規則全体を JSON で直せる。JSON を変えていなければ欄の値を採る' do
    draft = draft()
    json = rule(draft, 'path_rule').except('confirmed').merge('paths' => [%w[role_a], %w[role_b], %w[role_c]]).to_json
    save draft, rules: [{ id: 'path_rule', json: json, label: '欄の値は採られない' }]

    assert_equal 3, rule(draft, 'path_rule')['paths'].size
    assert_equal '規則path_rule', rule(draft, 'path_rule')['label']
    assert rule(draft, 'path_rule')['confirmed']

    same = JSON.pretty_generate(rule(draft, 'humanities').except('confirmed'))
    save draft, rules: [{ id: 'humanities', json: same, required_credits: '7' }]
    assert_equal 7, rule(draft, 'humanities')['required_credits']
  end

  test 'JSON が壊れている・id を変えている・オブジェクトでないときは保存しない' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', json: '{ こわれた' }]
    assert_match(/JSON を読めません/, flash[:alert])

    save draft, rules: [{ id: 'humanities', json: '{"id":"other","type":"credit_sum"}' }]
    assert_match(/id は変えられません/, flash[:alert])

    save draft, rules: [{ id: 'humanities', json: '[1]' }]
    assert_match(/規則1つ分のオブジェクト/, flash[:alert])
    assert_equal 4, rule(draft, 'humanities')['required_credits']
  end

  test '規則を足せる。足した規則には印が付き、id の重複と型の誤りは断る' do
    draft = draft()
    save draft,
         new_rule_json: { id: 'extra', type: 'credit_sum', label: '追加', categories: ['english'],
                          required_credits: 2 }.to_json

    assert rule(draft, 'extra')['confirmed']
    assert_equal 8, draft.document['rules'].size

    save draft, new_rule_json: { id: 'extra', type: 'credit_sum' }.to_json
    assert_match(/すでにあります/, flash[:alert])
    save draft, new_rule_json: { id: 'another', type: 'magic' }.to_json
    assert_match(/type は次のどれかにしてください/, flash[:alert])
    save draft, new_rule_json: { type: 'credit_sum' }.to_json
    assert_match(/id\(文字列\)が要ります/, flash[:alert])
    assert_equal 8, draft.reload.document['rules'].size
  end

  test '直した文書でも、突き合わせは公開を止めない(確認の印は文書を壊さない)' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: '5' }],
                display: { groups: [{ id: 'common', title: '1. 共通教育・直した', rows: [{ id: 'english', name: '英語' }] }] }

    validation = CurriculumImport::Validation.for(draft.reload)
    assert_not validation.blocking?, validation.call.inspect
    assert_nothing_raised { GraduationAssessment::Catalogue.new(draft.document) }
  end

  # ---- 注釈 ----

  def card_id(draft, kind)
    CurriculumImport::Annotations.cards(draft.reload.document, draft.pages).find { |card| card.kind == kind }.id
  end

  test '注釈を「判定に反映しない」にすると、記録だけ残して判定は変わらない' do
    page = { 'page' => 6, 'kind' => 'requirements', 'status' => 'read', 'text' => '備考 外国人留学生の特例は別に定める。' }
    draft = draft(extra_pages: [page])
    id = card_id(draft, :foreign_student)
    rules_before = draft.document['rules']
    save draft, annotations: { id => { disposition: 'ignore' } }

    decision = draft.reload.document['annotation_decisions'][id]
    assert_equal 'ignore', decision['disposition']
    assert_equal rules_before, draft.document['rules']
    show(draft)
    assert_select "#annotation-#{id}", text: /判定に反映しないと決めて、記録しました/
  end

  test '科目に当てられなかった承認の注記に区分を選ぶと、その区分の科目に承認の関門が付く' do
    warning = CurriculumImport::ApprovalNotes.unresolved_warning('他学部の科目は指導教員の承認が必要')
    page = { 'page' => 5, 'kind' => 'requirements', 'status' => 'read', 'text' => '', 'warnings' => [warning] }
    draft = draft(extra_pages: [page])
    id = card_id(draft, :approval_unattached)
    save draft, annotations: { id => { disposition: 'approval', category: 'fusion' } }

    document = draft.reload.document
    assert_equal({ 'scope' => 'category', 'category' => 'fusion', 'text' => '他学部の科目は指導教員の承認が必要' },
                 document['approval_notes'].first)
    gated, ungated = document['courses'].partition { |course| course['category'] == 'fusion' }
    assert(gated.all? { |course| course['requires_approval'] })
    assert(ungated.none? { |course| course['requires_approval'] })
    assert_equal 'fusion', document['annotation_decisions'][id]['category']
  end

  test '承認の注記は、区分を選ばないと作らず、作ったあとは変えられない' do
    warning = CurriculumImport::ApprovalNotes.unresolved_warning('承認が必要')
    draft = draft(extra_pages: [{ 'page' => 5, 'kind' => 'requirements', 'status' => 'read', 'text' => '',
                                  'warnings' => [warning] }])
    id = card_id(draft, :approval_unattached)
    save draft, annotations: { id => { disposition: 'approval', category: 'nowhere' } }
    assert_match(/区分を選んでください/, flash[:alert])

    save draft, annotations: { id => { disposition: 'approval', category: 'fusion' } }
    save draft, annotations: { id => { disposition: 'ignore' } }
    assert_match(/承認の注記は、ここからは外せません/, flash[:alert])
  end

  test '注釈を規則の型に割り当てると、中身が空の規則が足され、埋めるまで公開を止める' do
    page = { 'page' => 6, 'kind' => 'requirements', 'status' => 'read', 'text' => '備考 外国人留学生の特例は別に定める。' }
    draft = draft(extra_pages: [page])
    id = card_id(draft, :foreign_student)
    save draft, annotations: { id => { disposition: 'credit_sum' } }

    added = rule(draft, "annotation_#{id}")
    assert_equal ['credit_sum', true, nil, []],
                 [added['type'], added['confirmed'], added['required_credits'], added['categories']]
    assert CurriculumImport::Validation.for(draft.reload).blocking?, '数字が空のまま公開されない'
    show(draft)
    assert_select '#requirements_findings [data-blocking=true]', text: /必要な欄が無いか、形が違います: required_credits/

    save draft, annotations: { id => { disposition: 'ignore' } }
    assert_match(/すでに規則「annotation_#{id}」を作ってあります/, flash[:alert])
  end

  test '7つの型のどれでもない割り当てと、見つからない注釈は断る' do
    page = { 'page' => 6, 'kind' => 'requirements', 'status' => 'read', 'text' => '外国人留学生の特例' }
    draft = draft(extra_pages: [page])
    id = card_id(draft, :foreign_student)
    save draft, annotations: { id => { disposition: 'all_of' } }
    assert_match(/規則の型を選んでください/, flash[:alert])

    save draft, annotations: { 'deadbeef' => { disposition: 'ignore' } }
    assert_match(/この注釈は見つかりません/, flash[:alert])
  end

  test '反映済みの承認の注記は、ここでは選ばせない' do
    document = requirements_document
    document['approval_notes'] =
      [{ 'scope' => 'category', 'category' => 'fusion', 'text' => '承認が必要', 'source_page' => 'PDF2ページ' }]
    draft = draft(document: document)
    id = card_id(draft, :approval_applied)
    show(draft)
    assert_select "#annotation-#{id} form", count: 0

    save draft, annotations: { id => { disposition: 'ignore' } }
    assert_match(/見つかりません/, flash[:alert])
  end

  # ---- 実物と、画面からの読み直し ----

  test '実物の2024年度の文書でも、画面は開き、表と注意が出る' do
    document = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    show(draft(document: document))

    assert_response :success
    assert_select 'tr', text: /1\. 共通教育 合計.*30/
    assert_select 'tr', text: /卒業に必要な総単位.*130/
    assert_select '#requirements_rules li', count: document['rules'].size
    assert_select '#requirements_findings [data-blocking=true]', count: 0
    assert_select '#category-excluded', text: /総単位に数えない/
  end

  # 画面のフォームを、ブラウザと同じように送り返す(入力欄・チェック済みの箱・選択・テキストエリアの中身)。
  # 触らずに送り返したとき、何も「直した」ことにならないこと(確認の印が付かないこと)を、実物の画面で確かめるため。
  def browser_pairs(draft)
    get curriculum_path(draft), env: ENV_LOCAL
    form = response.parsed_body.at_css('#requirements_form')
    form.css('input, textarea, select').filter_map { |field| browser_value(field) }
  end

  def browser_value(field)
    name = field['name']
    return if name.blank? || field['type'] == 'submit' || %w[_method authenticity_token].include?(name)
    return if %w[checkbox radio].include?(field['type']) && field['checked'].nil?

    [name, browser_field_value(field)]
  end

  def browser_field_value(field)
    case field.name
    when 'textarea' then field.text.delete_prefix("\n")
    when 'select' then field.at_css('option[selected]')&.[]('value').to_s
    else field['value'].to_s
    end
  end

  def submit_pairs(draft, pairs)
    patch update_rules_curriculum_path(draft), params: URI.encode_www_form(pairs),
                                               headers: { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' },
                                               env: ENV_LOCAL
  end

  test '触らずに保存しても、何も直したことにならず、確認の印も付かない(実物の文書)' do
    document = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    draft = draft(document: document)
    submit_pairs(draft, browser_pairs(draft))

    assert_match(/変えた箇所はありませんでした/, flash[:notice])
    assert_equal document, draft.reload.document
  end

  test '触らずに保存しても、何も直したことにならない(人工の文書。消す・並びの欄も含む)' do
    draft = draft()
    submit_pairs(draft, browser_pairs(draft))

    assert_match(/変えた箇所はありませんでした/, flash[:notice])
    assert_equal requirements_document, draft.reload.document
  end

  test '画面のフォームのまま1つだけ値を変えて保存すると、その項目にだけ印が付く' do
    draft = draft()
    target = 'rules[0][required_credits]'
    pairs = browser_pairs(draft).map { |name, value| name == target ? [name, '5'] : [name, value] }
    assert_includes pairs, [target, '5']
    submit_pairs(draft, pairs)

    assert_equal [5], [rule(draft, 'humanities')['required_credits']]
    confirmed = draft.document['rules'].select { |entry| entry['confirmed'] }.pluck('id')
    assert_equal %w[humanities], confirmed
    assert(groups(draft).none? { |entry| entry['confirmed'] })
  end

  # 読み取りの窓口の代役。要件表のページを読むと、決めた答えを返す。
  class FixedReader
    def initialize(answer)
      @answer = answer
    end

    def read_requirements(**) = @answer
  end

  test '画面で直した必要単位は、そのページを読み直しても AI の値に戻らず、違いは行の警告に出る' do
    draft = draft()
    FileUtils.mkdir_p(draft.images_dir)
    File.binwrite(draft.images_dir.join('p2.png'), "\x89PNG".b)
    save draft, rules: [{ id: 'humanities', required_credits: '5' }]
    answer = { 'categories' => draft.document['categories'], 'roles' => [],
               'rules' => [fixture_rule('humanities', 'credit_sum', categories: ['humanities'], required_credits: 8)],
               'display' => { 'groups' => [] } }

    CurriculumReader.stub(:available?, true) do
      CurriculumReader.stub(:new, FixedReader.new(answer)) do
        post read_page_curriculum_path(draft, page: 2), headers: { 'Accept' => 'text/vnd.turbo-stream.html' },
                                                        env: ENV_LOCAL
      end
    end

    assert_response :success
    assert_equal 5, rule(draft, 'humanities')['required_credits']
    assert_match(%r{規則「humanities」は人が直した内容を残しました.*必要単位\(残した値: 5 / 読み直した値: 8\)}, response.body)
  ensure
    FileUtils.rm_rf(draft.images_dir) if draft
  end

  # ---- 読み直す前の警告 ----

  test '人が直したものがあるページの「読み直す」には、確認の文が付く' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: '5' }],
                display: { groups: [{ id: 'common', _destroy: '1' }] }
    CurriculumReader.stub(:available?, true) { show(draft) }

    assert_select 'li[data-page="2"][data-reread-warning]' do |rows|
      warning = rows.first['data-reread-warning']
      assert_match(/2ページを読み直します/, warning)
      assert_match(/規則: 規則humanities\(humanities\)/, warning)
      assert_match(/読み直した結果では上書きせず/, warning)
      assert_match(/人が消した次の項目は、読み直しても戻しません: 章「common」/, warning)
    end
  end

  test '人が直したものが無いページには、確認の文を付けない' do
    CurriculumReader.stub(:available?, true) { show(draft) }

    assert_select 'li[data-page="2"]'
    assert_select 'li[data-reread-warning]', count: 0
  end
end

