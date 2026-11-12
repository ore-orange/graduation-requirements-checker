# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require_relative '../support/requirements_draft_fixtures'

# 要件表の確認画面。AI が読んだ規則・区分・表示を人が見て直す、ただ1つの場所。
# 見せること(誤読が見える)と、直した値が読み直しから守られること(印が付く)を確かめる。
class CurriculaRequirementsReviewTest < ActionDispatch::IntegrationTest
  include RequirementsDraftFixtures
  include RequirementsScreenHelpers

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
  end

  teardown do
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
  end

  # ---- 見せる ----

  test '区分ごとの必要単位の表が出る' do
    show(draft)

    assert_response :success
    # 章・行はツリーの入れ子。数字は値ではなく入力欄に入っている(開かなくても直せる)。
    assert_select '#group-common input[name=?][value=?]', 'display[groups][0][title]', '1. 共通教育'
    assert_select '#group-common input[name=?][value=?]', 'display[groups][0][required_credits]', '6'
    assert_select '#row-humanities input[name=?][value=?]', 'display[groups][0][rows][0][name]', '行humanities'
    assert_select '#row-humanities input[name=?][value=?]', 'display[groups][0][rows][0][required_credits]', '4'
    assert_select '#requirements_table input[name=?][value=?]', 'display[total_credits]', '14'
    assert_select '#group-required input[name=?][value=?]', 'display[groups][1][title]', '2. 必修'
  end

  # 畳むのは、PDFと突き合わせるときに目で追わない値だけ(各段の「…」と、科目の一覧)。
  # 判定の数字を決める値は、畳んだ中に入れない。畳んだ中の誤読は、人が開かないと見つからない(設計書 項目2)。
  test '判定の数字を決める値は、畳んだ中に入れない' do
    show(draft)

    judging = ['display[total_credits]', 'display[groups][0][required_credits]',
               'display[groups][0][rows][0][required_credits]', 'rules[0][required_credits]']
    judging.each do |name|
      fields = css_select("#requirements_form [name='#{name}']")
      assert_predicate fields, :any?, "#{name} が画面にありません"
      fields.each { |field| assert_empty field.ancestors('details'), "#{name} が畳んだ中にあります" }
    end
    # いま数えている区分(チェックが入っている区分)も畳まない。選んでいない区分だけが「＋」の中。
    ['display[groups][0][rows][0][categories][]', 'rules[0][categories][]'].each do |name|
      checked = css_select("#requirements_form input[name='#{name}'][checked]")
      assert_predicate checked, :any?, "#{name} の選んである区分が画面にありません"
      checked.each { |field| assert_empty field.ancestors('details'), "#{name} が畳んだ中にあります" }
    end
    # 出典も畳まない(PDFと突き合わせる唯一の手がかり。設計書 項目7)
    assert_select '#rule-humanities > p', text: /出典 PDF3ページ/
  end

  test '章・行の名前と必要単位は、開かなくても直せる(常時表示の入力欄)' do
    show(draft)

    assert_select '#group-common > div input[name=?]', 'display[groups][0][title]'
    assert_select '#row-humanities > div input[name=?]', 'display[groups][0][rows][0][name]'
  end

  # 行を確かめる規則のうち、入れ子を持つもの(one_of_paths・any_of・all_of)は、行の下に
  # AND/OR のバッジ付きで中身を出す。畳まれた JSON の中にあると、読み違えが見つからない。
  test '入れ子を持つ規則は、行の下にAND/ORのバッジと中身が出る' do
    document = requirements_document
    document['display']['groups'][0]['rows'][0]['check_ids'] = %w[humanities path_rule]

    show(draft(document: document))

    assert_select '#row-humanities [data-rule-logic=?]', 'OR'
    assert_select '#row-humanities [data-rule-box=?]', 'path_rule', text: /経路1/
  end

  # 入れ子を持たない規則(credit_sum など)も箱で出すが、AND/OR のバッジは付けない。
  test 'バッジが付くのは、入れ子を持つ規則だけ' do
    show(draft)

    assert_select '#row-humanities [data-rule-box=?]', 'humanities'
    assert_select '#row-humanities [data-rule-logic]', count: 0
  end

  # 行に常時出るのは、PDFと突き合わせるときに目で追う4つ(必要単位・科目名・対象科目・修了要件)。
  # 対象の区分名は、行の名前と同じでも省略しない(設計書 項目2)。
  test '行には、対象の区分名・科目の件数・確かめる決まりが、常時出る' do
    show(draft)

    assert_select '#row-humanities', text: /対象：/
    assert_select '#row-humanities input[type=checkbox][name=?][value=?][checked]',
                  'display[groups][0][rows][0][categories][]', 'humanities'
    assert_select '#row-humanities summary', text: /科目 3件/
    assert_select '#row-humanities [data-rule-box=?]', 'humanities', text: /規則humanities/
  end

  # 23個のチェックの並びはやめ、選んである区分だけをチップで出す。足すのは選択肢1つから。
  # チェックを毎行に23個並べると、行と決まりの数だけ繰り返して1画面が重くなる。
  test '対象の区分は、選んであるものだけをチップで出し、足すのは選択肢から' do
    show(draft)

    name = 'display[groups][0][rows][0][categories][]'
    assert_equal %w[humanities], css_select("#row-humanities input[name='#{name}'][checked]").pluck('value')
    assert_equal 1, css_select("#row-humanities input[type=checkbox][name='#{name}']").size
    # 足す区分は、チップに無い区分だけが選択肢に出る(同じ値を2か所から送らない)
    options = css_select("#row-humanities select[name='display[groups][0][rows][0][add][categories]'] option")
    assert_equal %w[english required_core fusion excluded], options.pluck('value').compact_blank
  end

  # 1つの打ち間違いで保存できなかったとき、「＋」で足した区分も、チップとして残る。
  test '保存できなかったとき、足した区分もチップに残る' do
    draft = draft()
    pairs = browser_pairs(draft)
    pairs = pairs.map { |name, value| name == 'rules[0][required_credits]' ? [name, 'たくさん'] : [name, value] }
    pairs << ['display[groups][0][rows][0][add][categories]', 'english']
    submit_pairs(draft, pairs)

    assert_response :unprocessable_content
    name = 'display[groups][0][rows][0][categories][]'
    assert_equal %w[humanities english].sort,
                 css_select("#row-humanities input[name='#{name}'][checked]").pluck('value').sort
  end

  # 件数を押すと、その場で科目名・科目番号・単位数が出る。科目は表示だけで、フォームの欄にはしない。
  test '科目の一覧は表示だけで、フォームの欄にはしない' do
    show(draft)

    courses = css_select('#row-humanities details').find { |node| node.at_css('summary')&.text&.include?('科目') }
    assert_not_nil courses
    assert_equal '', courses.css('input, select, textarea').to_s
    assert_match(/人101/, courses.text)
    assert_match(/哲学/, courses.text)
  end

  # 1件だけの行は、最初から開いた状態にする(押さなくても読める)。
  test '科目が1件だけの行は、最初から開いている' do
    document = requirements_document
    document['courses'] = [fixture_course('人101', '哲学', 'humanities')]
    show(draft(document: document))

    opened = css_select('#row-humanities details[open]')
    assert(opened.any? { |node| node.at_css('summary')&.text&.include?('科目 1件') })
  end

  # number_patterns は、科目表に無い科目をどの区分に数えるかを決める値。判定の数字を決める値は、
  # 画面に出して人が直せるようにする(出ていない値は、読み違えても誰も気づけない)。
  test '区分の科目番号パターンが画面に出て、欄から直せる' do
    document = requirements_document
    document['categories'][0]['number_patterns'] = ['人']
    draft = draft(document: document)

    show(draft)

    assert_select '#category-humanities', text: /人/
    assert_select '#category-humanities input[name=?][value=?]', 'categories[0][number_patterns]', '人'

    save draft, categories: [{ key: 'humanities', number_patterns: '人, 社' }]

    category = draft.reload.document['categories'].find { |entry| entry['key'] == 'humanities' }
    assert_equal %w[人 社], category['number_patterns']
    assert category['confirmed']
  end

  test '区分の一覧が出て、総単位に数えない区分は赤で出る' do
    show(draft)

    assert_select '#requirements_categories li', count: 5
    assert_select '#category-excluded .text-rose-700', text: /総単位に数えない/
  end

  # どの章・行・枠からも指されていない決まりは、判定には効くのに学生の画面のどの行にも出ない。
  # 画面から消すとその要件が見えなくなるので、必ず専用の枠に出す(設計書 項目6)。
  test 'どこからも指されていない決まりは、専用の枠に出る' do
    show(draft)

    # 人工の文書では total(総単位の決まり)が総単位の枠、excluded_category が算入しない科目の枠に出る。
    # 残り(どの行も指していない決まり)が、この枠に出る。
    assert_select '#total_credits_row [data-rule-box=?]', 'total'
    assert_select '#requirements_excludes [data-rule-box=?]', 'excluded_category'
    # path_rule は、人工の文書ではどの行も指していない。その枠に出る
    assert_select '#requirements_rules li [data-rule-box=?]', 'path_rule'
    assert_select '#requirements_rules li [data-rule-box]', count: 1
  end

  test '読み取り直後にどこからも指されていない決まりも、黙って隠さない' do
    document = requirements_document
    document['rules'] << fixture_rule('lost', 'credit_sum', categories: ['english'], required_credits: 2)
    show(draft(document: document))

    assert_select '#requirements_rules li [data-rule-box=?]', 'lost'
    # 結びつける先は、章・枠・行の名前で選ぶ(id は打たない。設計書 項目5)
    assert_select '#requirements_rules select[name=?] option', 'rules[7][link]', text: '行: 1. 共通教育 / 行humanities'
  end

  # 決まりは、この画面の中で1か所だけが欄を持つ。2か所に出すと、同じ名前のパラメータが2回送られ、
  # 触っていない決まりが「直した」ことになってしまう。
  test '1つの決まりの欄は、画面の中で1組だけ' do
    show(draft)

    ids = %w[humanities english path_rule core fusion_provider total excluded_category]
    ids.each { |id| assert_select '[data-rule-box=?]', id, count: 1 }
    # 決まり1つにつき、id の hidden が1つだけ(欄の名前が重なっていない)
    names = css_select('#requirements_form input[type=hidden]').pluck('name').grep(/\Arules\[\d+\]\[id\]\z/)
    assert_equal ids.size, names.size
    assert_equal names.uniq, names
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

  # 同じ規則を2つの行が指していても、欄は1組だけ出す(2組出すと、同じ名前のパラメータが2回送られ、
  # 触っていない規則が「直した」ことになってしまう)。
  test '同じ入れ子の規則を2つの行が指しても、欄は1組しか出さない' do
    document = requirements_document
    document['display']['groups'][0]['rows'][0]['check_ids'] = %w[path_rule]
    document['display']['groups'][0]['rows'][1]['check_ids'] = %w[path_rule]
    draft = draft(document: document)

    show(draft)

    assert_select '[data-rule-box=?]', 'path_rule', count: 1
    assert_select '[data-rule-paths=?]', 'path_rule', count: 1
    # 経路1つにつき、空送信用の hidden と役割のチェックが1組だけ(2組出ると同じ名前で2回送られる)
    assert_select 'input[name=?][type=hidden]', 'rules[2][paths][0][roles][]', count: 1
  end

  test '2つの行が同じ入れ子の規則を指す画面を、触らずに送り返しても何も変わらない' do
    document = requirements_document
    document['display']['groups'][0]['rows'][0]['check_ids'] = %w[path_rule]
    document['display']['groups'][0]['rows'][1]['check_ids'] = %w[path_rule]
    draft = draft(document: document)

    submit_pairs(draft, browser_pairs(draft))

    assert_match(/変えた箇所はありませんでした/, flash[:notice])
    assert_equal document, draft.reload.document
  end

  test '突き合わせの結果が画面に出る' do
    document = requirements_document
    document['display']['groups'][0]['rows'][0]['check_ids'] = %w[humanities vanished]
    show(draft(document: document))

    assert_select 'body', text: /規則が見つかりません/
    assert_select '#requirements_findings [data-blocking=true]', text: /vanished/
    assert_select '#requirements_findings', text: /公開を止める問題が1件/
    # 該当の行の中にも、同じ理由が出る
    assert_select '#row-humanities', text: /規則が見つかりません: vanished/
    # 行が確かめている決まりは、id ではなく名前で出る(設計書 項目5)
    assert_select '#row-humanities [data-rule-box=?]', 'humanities', text: /規則humanities/
    assert_select '#row-humanities .text-rose-900', text: /規則が見つかりません: vanished/
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
    # 章「elective」を消すと、その中の行「fusion」だけが指していた決まりも消える(設計書 項目5)。
    assert_equal([%w[rule english 2], %w[row english 2], %w[group elective 2], ['subtotal', 'sub', ''],
                  %w[rule fusion_provider 2]],
                 document['removed_by_human'].map { |entry| [entry['kind'], entry['id'], entry['page'].to_s] })
  end

  # ---- 算入しない科目(設計書 項目9) ----

  test '算入しない科目の枠に、区分・提供コース・科目番号の欄が出る' do
    show(draft)

    key = '#requirements_excludes [data-rule-box=excluded_category]'
    assert_select "#{key} select[name=?]", 'rules[6][category]'
    assert_select "#{key} select[name=?]", 'rules[6][number_prefix]'
    assert_select "#{key} input[type=radio][name=?][value=?]", 'rules[6][number_prefix_mode]', 'match'
    assert_select "#{key} input[type=radio][name=?][value=?]", 'rules[6][number_prefix_mode]', 'except'
    assert_select "#{key} input[name=?]", 'rules[6][numbers]'
  end

  # 便覧は提供コースの名前を持たないので、科目番号の接頭辞で表す。選択肢は科目表に出てくる接頭辞から作る。
  test '提供コースの選択肢は、科目表に出てくる接頭辞から作り、当たる科目を例示する' do
    show(draft)

    options = css_select('#requirements_excludes select[name="rules[6][number_prefix]"] option')
    assert_equal ['', '人', '外', '知能', '機械', '情'], options.pluck('value')
    assert_match(/機械.*熱力学/, options.find { |option| option['value'] == '機械' }.text)
  end

  test '算入しない科目の条件を直せる(区分＋提供コースの一致・以外)' do
    draft = draft()
    save draft, rules: [{ id: 'excluded_category', category: 'fusion', number_prefix: '機械',
                          number_prefix_mode: 'except', reason: '他コース提供以外は算入しない' }]

    assert_equal ['fusion', '機械', 'except', '他コース提供以外は算入しない', true],
                 rule(draft, 'excluded_category').values_at('category', 'number_prefix', 'number_prefix_mode',
                                                            'reason', 'confirmed')
  end

  test '算入しない科目を、科目番号だけで直せる(区分を空にできる)' do
    draft = draft()
    save draft, rules: [{ id: 'excluded_category', category: '', numbers: '情01、理101 農201' }]

    excluded = rule(draft, 'excluded_category')
    assert_not excluded.key?('category')
    assert_equal %w[情01 理101 農201], excluded['numbers']
  end

  # 条件が全部空の除外は、すべての科目を算入から外す。保存を断る(学生の単位が黙って消える)。
  test '条件が全部空の除外は断る' do
    draft = draft()
    save draft, rules: [{ id: 'excluded_category', category: '', number_prefix: '', numbers: '' }]

    assert_match(/区分・提供コース.*科目番号.*を書いてください/, response.body)
    assert_equal 'excluded', rule(draft, 'excluded_category')['category']
  end

  test '算入しない科目を足せる' do
    draft = draft()
    save draft, new_exclude: { category: 'fusion', number_prefix: '知能', number_prefix_mode: 'match',
                               numbers: '', reason: '自コース提供の工学融合科目は算入不可' }

    added = draft.reload.document['rules'].last
    assert_equal ['exclude', 'fusion', '知能', '自コース提供の工学融合科目は算入不可', true],
                 added.values_at('type', 'category', 'number_prefix', 'reason', 'confirmed')
    assert_equal 'added_rule_1', added['id']
    # 空の欄・既定のままの欄(「一致」)は、欄ごと持たせない。
    assert_not added.key?('numbers')
    assert_not added.key?('number_prefix_mode')
  end

  test '算入しない科目を、条件なしでは足せない' do
    draft = draft()
    save draft, new_exclude: { category: '', number_prefix: '', numbers: '', reason: '何となく' }

    assert_match(/区分・提供コース.*科目番号.*を書いてください/, response.body)
    assert_equal 7, draft.reload.document['rules'].size
  end

  test '算入しない科目を、理由なしでは足せない' do
    draft = draft()
    save draft, new_exclude: { category: 'fusion', reason: '' }

    assert_match(/算入しない理由/, response.body)
    assert_equal 7, draft.reload.document['rules'].size
  end

  # ---- 行を消すと、その行だけが指していた決まりも消える(設計書 項目5) ----

  test '行を消すと、その行だけが指していた決まりも消える' do
    draft = draft()
    save draft, display: { groups: [{ id: 'common', rows: [{ id: 'english', _destroy: '1' }] }] }

    document = draft.reload.document
    assert_not_includes document['rules'].pluck('id'), 'english'
    assert_equal([%w[row english], %w[rule english]],
                 document['removed_by_human'].map { |entry| entry.values_at('kind', 'id') })
  end

  test '行を消しても、ほかの行や章も指している決まりは残る' do
    document = requirements_document
    document['display']['groups'][2]['rows'] << fixture_row('fusion2', ['fusion'], ['fusion_provider'], 2)
    draft = draft(document: document)
    save draft, display: { groups: [{ id: 'elective', rows: [{ id: 'fusion', _destroy: '1' }] }] }

    assert_includes draft.reload.document['rules'].pluck('id'), 'fusion_provider'
  end

  test '章を消すと、その章の行だけが指していた決まりも消える' do
    draft = draft()
    save draft, display: { groups: [{ id: 'common', _destroy: '1' }] }

    ids = draft.reload.document['rules'].pluck('id')
    assert_not_includes ids, 'humanities'
    assert_not_includes ids, 'english'
    assert_includes ids, 'total'
  end

  test '総単位を直すと、その値を足したページの記録から外れる(読み直しで消えない)' do
    draft = draft()
    save draft, display: { total_credits: '16' }

    assert_equal 16, draft.reload.document['display']['total_credits']
    assert_equal 'human', draft.pages.find { |page| page['page'] == 2 }['contributed']['total_credits']
  end

  test '数でない値は、何も保存せず、どの欄かを言う' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: 'たくさん' }], display: { total_credits: '16' }

    assert_match(/規則「humanities」の必要単位は数で入れてください/, response.body)
    assert_equal 4, rule(draft, 'humanities')['required_credits']
    assert_equal 14, draft.document['display']['total_credits'], '一部だけ保存せず、全部を保存しない'
  end

  test '下書きに無い id を送ったら、何も保存せずに知らせる' do
    draft = draft()
    save draft, rules: [{ id: 'nothing', label: 'x' }]

    assert_match(/規則「nothing」は下書きにありません/, response.body)
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

  test '指紋を送らない保存は受けない(画面から保存するときだけ、古い画面かどうかが確かめられる)' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: '5' }], with_revision: false

    assert_response :unprocessable_content
    assert_match(/指紋\(revision\)が送られていない/, response.body)
    assert_equal 4, rule(draft, 'humanities')['required_credits']
  end

  # JSON の欄は無くした。経路も入れ子の条件も、それぞれの欄で直す。
  test '経路は、JSON ではなく欄から直す' do
    draft = draft()
    save draft, rules: [{ id: 'path_rule', paths: { 'a' => { roles: %w[role_a] }, 'b' => { roles: %w[role_b] },
                                                    'c' => { roles: %w[role_a role_b] } } }]

    assert_equal 3, rule(draft, 'path_rule')['paths'].size
    assert rule(draft, 'path_rule')['confirmed']
  end

  test '規則の画面に JSON の欄は無い' do
    show(draft)

    assert_select 'textarea[name*=?]', '[json]', count: 0
  end

  # 人は規則の id を一度も打たない。id はアプリが裏で振る(設計書 項目5)。
  test '決まりを足せる。id は自動で付き、足した決まりには印が付く' do
    draft = draft()
    save draft, new_rule: { type: 'credit_sum', label: '追加', fields: { 'credit_sum' => { categories: ['english'],
                                                                                         required_credits: '2' } } }

    added = draft.reload.document['rules'].last
    assert_equal 'added_rule_1', added['id']
    assert_equal [2, %w[english], '追加', true],
                 added.values_at('required_credits', 'categories', 'label', 'confirmed')
    assert_equal 8, draft.document['rules'].size

    save draft, new_rule: { type: 'magic', label: 'あやしい' }
    assert_match(/種類は次のどれかにしてください/, response.body)
    assert_equal 8, draft.reload.document['rules'].size
  end

  # 足した決まりは、章・枠・行を名前で選んで結びつける。id はその行の id から作る(<行の id>_c1)。
  test '足した決まりを行に結びつけると、id は行の id から付き、その行が確かめる' do
    draft = draft()
    save draft, new_rule: { type: 'credit_sum', label: '足した要件', link: 'row:humanities',
                            fields: { 'credit_sum' => { categories: ['english'], required_credits: '3' } } }

    row = group(draft, 'common')['rows'].first
    assert_equal %w[humanities humanities_c1], row['check_ids']
    assert row['confirmed']
    assert_equal 3, rule(draft, 'humanities_c1')['required_credits']
  end

  # すでにある決まりも、id を打たずに名前で選んで結びつけられる。
  # 結びつけただけでは、その決まりの値に印は付かない(変えたのは結びつけだけ)。
  test 'すでにある決まりを、章に名前で結びつけられる' do
    draft = draft()
    save draft, rules: [{ id: 'total', link: 'group:common' }]

    assert_equal 'total', group(draft, 'common')['check_id']
    assert group(draft, 'common')['confirmed']
    assert_nil rule(draft, 'total')['confirmed']
  end

  # 章の check_id は単数。配列にすると公開済みの便覧が持てる欄の形が変わるので、2つめは断る(設計書 項目6)。
  test 'すでに決まりを持つ章には、2つめを結びつけない' do
    draft = draft()
    save draft, rules: [{ id: 'total', link: 'group:required' }]

    assert_match(/すでに決まり「core」を確かめています/, response.body)
    assert_equal 'core', group(draft, 'required')['check_id']
  end

  test '結びつける先が下書きに無ければ、何も保存しない' do
    draft = draft()
    save draft, rules: [{ id: 'total', link: 'row:nope' }]

    assert_match(/結びつける先の行「nope」が下書きにありません/, response.body)
    assert_equal requirements_document, draft.reload.document
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
    assert_match(/区分を選んでください/, response.body)

    save draft, annotations: { id => { disposition: 'approval', category: 'fusion' } }
    save draft, annotations: { id => { disposition: 'ignore' } }
    assert_match(/承認の注記は、注記の一覧から外してください/, response.body)
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
    assert_match(/すでに規則「annotation_#{id}」を作ってあります/, response.body)
  end

  test '7つの型のどれでもない割り当てと、見つからない注釈は断る' do
    page = { 'page' => 6, 'kind' => 'requirements', 'status' => 'read', 'text' => '外国人留学生の特例' }
    draft = draft(extra_pages: [page])
    id = card_id(draft, :foreign_student)
    save draft, annotations: { id => { disposition: 'all_of' } }
    assert_match(/規則の型を選んでください/, response.body)

    save draft, annotations: { 'deadbeef' => { disposition: 'ignore' } }
    assert_match(/この注釈は見つかりません/, response.body)
  end

  test '反映済みの承認の注記は、ここでは選ばせない' do
    document = requirements_document
    document['approval_notes'] =
      [{ 'scope' => 'category', 'category' => 'fusion', 'text' => '承認が必要', 'source_page' => 'PDF2ページ' }]
    draft = draft(document: document)
    id = card_id(draft, :approval_applied)
    show(draft)
    assert_select "#annotation-#{id} select", count: 0
    assert_select "#annotation-#{id} input[name=remove_approval_note][value=?]", id

    save draft, annotations: { id => { disposition: 'ignore' } }
    assert_match(/見つかりません/, response.body)
  end

  # ---- 実物と、画面からの読み直し ----

  test '実物の2024年度の文書でも、画面は開き、表と注意が出る' do
    document = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    show(draft(document: document))

    assert_response :success
    assert_select '#group-common input[value=?]', '1. 共通教育'
    assert_select '#requirements_table input[name=?][value=?]', 'display[total_credits]', '130'
    assert_select '#requirements_findings [data-blocking=true]', count: 0
    assert_select '#category-excluded', text: /総単位に数えない/
    # 27個の決まりが、画面のどこかに1組ずつ出ている(どれも消えていない。設計書 項目6)
    boxes = css_select('[data-rule-box]').pluck('data-rule-box')
    assert_equal document['rules'].pluck('id').sort, boxes.sort
    # 置き場所: 総単位の枠・算入しない科目の枠・結びついていない決まりの枠
    assert_select '#total_credits_row [data-rule-box=?]', 'total'
    assert_select '#requirements_excludes [data-rule-box=?]', 'excluded_category'
    assert_select '#requirements_excludes [data-rule-box=?]', 'own_fusion'
    assert_select '#requirements_rules li [data-rule-box=?]', 'required_total'
    # 自然系の上限は、その区分を数える行の内側に出る(設計書 項目4)
    assert_select '#row-general_subtotal [data-rule-box=?]', 'natural_cap'
    # 小計は、まとめている3行を囲む枠になる(設計書 項目10)
    assert_select '#subtotal-elective_inner #row-elective_math'
    assert_select '#subtotal-elective_inner #row-advanced'
    assert_select '#subtotal-elective_inner #row-related'
    assert_select '#requirements_subtotals', count: 0
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

