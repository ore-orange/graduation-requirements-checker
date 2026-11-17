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
               'display[groups][0][rows][0][required_credits]', 'rules[3][required_credits]']
    judging.each do |name|
      fields = css_select("#requirements_form [name='#{name}']")
      assert_predicate fields, :any?, "#{name} が画面にありません"
      fields.each { |field| assert_empty field.ancestors('details'), "#{name} が畳んだ中にあります" }
    end
    # いま数えている区分(チェックが入っている区分)も畳まない。選んでいない区分だけが「＋」の中。
    ['display[groups][0][rows][0][categories][]', 'rules[3][required_categories][]'].each do |name|
      checked = css_select("#requirements_form input[name='#{name}'][checked]")
      assert_predicate checked, :any?, "#{name} の選んである区分が画面にありません"
      checked.each { |field| assert_empty field.ancestors('details'), "#{name} が畳んだ中にあります" }
    end
    # 出典も畳まない(PDFと突き合わせる手がかり)。決まりごとではなく、節に1度出す(設計書 項目4)
    assert_select '#requirements_review > div', text: /出典: PDF3ページ/
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
    assert_select '#row-humanities [data-rule-box=?]', 'path_rule', text: /次のどれか1組を、すべて修得/
  end

  # 入れ子を持たない規則(credit_sum など)も箱で出すが、AND/OR のバッジは付けない。
  test 'バッジが付くのは、入れ子を持つ規則だけ' do
    show(draft)

    assert_select '#row-fusion [data-rule-box=?]', 'fusion_provider'
    assert_select '#row-fusion [data-rule-logic]', count: 0
  end

  # 行に常時出るのは、PDFと突き合わせるときに目で追う4つ(必要単位・科目名・対象科目・修了要件)。
  # 対象の区分名は、行の名前と同じでも省略しない(設計書 項目2)。
  test '行には、対象の区分名・科目の件数・確かめる決まりが、常時出る' do
    show(draft)

    assert_select '#row-humanities', text: /対象：/
    assert_select '#row-humanities input[type=checkbox][name=?][value=?][checked]',
                  'display[groups][0][rows][0][categories][]', 'humanities'
    assert_select '#row-humanities summary', text: /科目 3件/
    # 確かめる決まりは、行と同じことを言っていなければ箱で出る(fusion_provider は grouped_max)
    assert_select '#row-fusion [data-rule-box=?]', 'fusion_provider', text: /規則fusion_provider/
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
    pairs = pairs.map { |name, value| name == 'rules[3][required_credits]' ? [name, 'たくさん'] : [name, value] }
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

  # ---- 画面に残っていた小さな傷(設計書 項目8) ----

  test '区分の一覧に、内部のキーを出さない' do
    show(draft)

    assert_select '#category-humanities', text: /人文系/
    assert_select '#category-humanities', text: /\(humanities\)/, count: 0
  end

  # 行は「対象：」、決まりは「数える区分」と、同じものを2つの言葉で呼んでいた。
  test '決まりの区分も、行と同じ「対象：」と呼ぶ' do
    show(draft)

    assert_select '#requirements_form', text: /数える区分/, count: 0
  end

  # 名前の欄が空の算入の上限は、型の名前が見出しにも横にも出て「算入の上限 算入の上限」になっていた。
  test '名前の無い決まりに、同じ言葉を二度出さない' do
    document = requirements_document
    document['rules'] << fixture_rule('natural_cap', 'cap', category: 'humanities', credits: 2).except('label')

    show(draft(document: document))

    assert_select '#rule-natural_cap', text: /算入の上限\s*算入の上限/, count: 0
  end

  # ---- 出典は節に1箇所(設計書 項目4) ----
  #
  # 2024年度は決まりが27個あり、「出典 …」が27回出ていた。中身は2種類しかない。

  test '出典は、節の見出しの下に1箇所だけ出る' do
    show(draft)

    assert_select '#requirements_review', text: /出典: PDF3ページ/
    assert_select '#rule-core > p', text: /出典/, count: 0
  end

  # 出典がばらばらなら、人が「この数字はPDFのどこか」を追えなくなる。そのときは決まりの横にも出す。
  test '出典が4種類以上あるときは、決まりごとにも出す' do
    document = requirements_document
    document['rules'].each_with_index { |rule, index| rule['source_page'] = "PDF#{index + 1}ページ" }

    show(draft(document: document))

    assert_select '#rule-core > p', text: /出典/
  end

  # 決まりごとに出すときも、隠した決まりには箱が無い。その出典が画面のどこにも出なくなるので、
  # 持ち主の「…」に入れる(人が見る値を減らさない)。
  test '出典が4種類以上あるとき、隠した決まりの出典は持ち主の … に出る' do
    document = requirements_document
    document['rules'].each_with_index { |rule, index| rule['source_page'] = "PDF#{index + 1}ページ" }

    show(draft(document: document))

    assert_select '#row-humanities details', text: /出典 PDF1ページ/
  end

  test '出典が無い下書きでは、出典の行を出さない' do
    document = requirements_document
    document['rules'].each { |rule| rule['source_page'] = nil }

    show(draft(document: document))

    assert_select '#requirements_review', text: /出典:/, count: 0
  end

  # ---- 残る決まりは、型の名前なしの日本語で出す(設計書 項目3) ----

  # 「区分の合計単位」「同じ提供元・言語から」はアプリの語彙。名前の横に並べても、人の助けにならない。
  test '決まりの箱に、型の名前を出さない' do
    show(draft)

    assert_select '#rule-fusion_provider', text: /同じ提供元・言語から/, count: 0
    assert_select '#rule-core', text: /必修をすべて修得/, count: 0
  end

  # 便覧に書いてある必修の科目数と、科目表の実数が食い違えば、転記漏れが分かる。並べて出す。
  test '必修をすべて修得する決まりに、科目表の実数を添える' do
    show(draft)

    assert_select '#rule-core', text: /科目表の必修は 2 科目/
  end

  # ---- 持ち主と同じことを言っている決まりは、箱を出さない(設計書 項目1) ----
  #
  # 2024年度の実データでは27個の決まりのうち12個が、すぐ上の行・章・枠と文字どおり同じ。
  # 同じことを二度書いた箱は、PDFと突き合わせる手がかりを増やさず、画面を読めなくするだけ。
  # 消すのは「人が打つ欄」であって「人が見る値」ではない。隠した値は、持ち主の行にそのまま出ている。

  test '行と同じことを言っている決まりの箱は、出さない' do
    show(draft)

    assert_select '[data-rule-box=?]', 'humanities', count: 0
    # 隠しても、その値は行に出ている
    assert_select '#row-humanities input[name=?][value=?]', 'display[groups][0][rows][0][required_credits]', '4'
    assert_select '#row-humanities input[type=checkbox][name=?][value=?][checked]',
                  'display[groups][0][rows][0][categories][]', 'humanities'
  end

  test '行と必要単位が食い違う決まりの箱は、出す' do
    document = requirements_document
    document['rules'].find { |rule| rule['id'] == 'humanities' }['required_credits'] = 6

    show(draft(document: document))

    assert_select '#row-humanities [data-rule-box=?]', 'humanities'
  end

  test '隠した決まりの名前と注記は、持ち主の … の中で直せる' do
    show(draft)

    assert_select '#row-humanities details input[name=?][value=?]', 'rules[0][label]', '規則humanities'
    assert_select '#row-humanities details input[name=?]', 'rules[0][detail]'
    # 保存が規則を引けるよう、id も送る
    assert_select '#row-humanities input[type=hidden][name=?][value=?]', 'rules[0][id]', 'humanities'
  end

  # 隠した決まりを「どこからも指されていない」枠が拾うと、同じ決まりが2か所に出て、欄が重複する。
  test '隠した決まりは、どの行にも結びついていない決まりの枠に落ちてこない' do
    show(draft)

    assert_select '#requirements_rules [data-rule-box=?]', 'humanities', count: 0
  end

  # 箱を隠すと、その決まりに付いた指摘を出す場所も消える。上のまとめには規則の id だけが残り、
  # 画面のどこからもその id を辿れなくなる。
  test '指摘が付いている決まりの箱は、重複していても出す' do
    document = requirements_document
    # 行が指す区分に科目が1つも無いと、突き合わせがその決まりを指す
    document['courses'].reject! { |course| course['category'] == 'humanities' }

    show(draft(document: document))

    assert_select '#row-humanities [data-rule-box=?]', 'humanities'
  end

  # ---- 自分の単位の決まりを持たない行(設計書 項目1-2) ----
  #
  # 章や枠が先に取った決まりを、その中の行も指していることがある。このとき行の required_credits は
  # 判定が使っていない数字で、入力欄のまま残すと「直しても判定が動かない」落とし穴がその行に残る。

  # 行の数字は、判定は使わないが、学生のカードには出る(display.rows[].required_credits)。
  # 欄ごと消すと、学生に出ている数字を直す手段が画面から無くなる。欄は残し、
  # 判定がどこの数字を見るかを、その横に書く。
  test '自分の単位の決まりを持たない行は、単位の欄を残し、判定がどこを見るかを添える' do
    show(draft)

    # 行 required_core が指す core は、章「2. 必修」が先に取っている
    assert_select '#row-required_core input[name=?]', 'display[groups][1][rows][0][required_credits]'
    assert_select '#row-required_core', text: /判定は章「2\. 必修」の4単位で見ます/
  end

  # どの章・行・枠からも指されていない決まりは、判定には効くのに学生の画面のどの行にも出ない。
  # 画面から消すとその要件が見えなくなるので、必ず専用の枠に出す(設計書 項目6)。
  test 'どこからも指されていない決まりは、専用の枠に出る' do
    show(draft)

    # 人工の文書では total(総単位の決まり)が総単位の枠、excluded_category が算入しない科目の枠に出る。
    # total は総単位の数字と同じことを言っているので、箱は出さず「…」に学生向けの文言だけを置く(設計書 項目1)。
    # 残り(どの行も指していない決まり)が、この枠に出る。
    assert_select '#total_credits_row input[type=hidden][name=?][value=?]', 'rules[5][id]', 'total'
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
    # 箱で出る決まりは、箱が1つだけ。持ち主と同じことを言っている決まりは箱を持たない(設計書 項目1)。
    %w[path_rule core fusion_provider excluded_category].each do |id|
      assert_select '[data-rule-box=?]', id, count: 1
    end
    %w[humanities english total].each { |id| assert_select '[data-rule-box=?]', id, count: 0 }
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
    # 行と同じことを言っている決まりは箱を出さないが、学生に出る名前は「…」で直せる(設計書 項目1・2-2)
    assert_select '#row-humanities input[name=?][value=?]', 'rules[0][label]', '規則humanities'
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

    # humanities の箱は行と同じことを言っているので出ない。印は、その値を出している行に付ける(設計書 項目1)
    assert_select '#row-humanities', text: /人が確認した/
    assert_select '#group-common', text: /人が確認した/
    assert_select '#row-english', text: /人が確認した/, count: 0
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
    # 27個の決まりが、画面のどこかに1組ずつ出ている(どれも消えていない。設計書 項目6)。
    # 持ち主と同じことを言っている12個は箱を持たず、持ち主の「…」が id・名前・説明を持つ(設計書 項目1)。
    hidden = css_select('#requirements_form input[type=hidden]').pluck('name', 'value')
    held = hidden.select { |name, _| name.match?(/\Arules\[\d+\]\[id\]\z/) }
    assert_equal document['rules'].pluck('id').sort, held.map(&:last).sort
    boxes = css_select('[data-rule-box]').pluck('data-rule-box')
    assert_equal 15, boxes.size
    # 置き場所: 総単位の枠・算入しない科目の枠・結びついていない決まりの枠
    assert_select '#total_credits_row input[type=hidden][value=?]', 'total'
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
    # 箱が出ている決まり(core は all_required なので、行と同じことを言っていない)を1つだけ直す
    target = 'rules[3][required_credits]'
    pairs = browser_pairs(draft).map { |name, value| name == target ? [name, '5'] : [name, value] }
    assert_includes pairs, [target, '5']
    submit_pairs(draft, pairs)

    assert_equal [5], [rule(draft, 'core')['required_credits']]
    confirmed = draft.document['rules'].select { |entry| entry['confirmed'] }.pluck('id')
    assert_equal %w[core], confirmed
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

  # ---- 科目番号パターンの候補 ----

  # 知能4xx の4科目(1つは人が確認済み)を区分 intel に足した下書き。候補は「知能4」。
  def draft_with_pattern_candidate
    document = requirements_document
    document['categories'] << { 'key' => 'intel', 'label' => '知能系', 'counts_toward_total' => true }
    document['courses'] += [fixture_course('知能401', 'A', 'intel'), fixture_course('知能402', 'B', 'intel'),
                            fixture_course('知能403', 'C', 'intel'),
                            fixture_course('知能404', 'D', 'intel', 'confirmed' => true)]
    draft(document: document)
  end

  test '区分の欄に、科目番号パターンの候補が出る' do
    show(draft_with_pattern_candidate)

    assert_response :success
    assert_select '#category-intel [data-pattern-suggestion=intel]', text: /知能4/
    assert_select '#category-intel input[type=checkbox][name=?][value=?]', 'adopt_patterns[intel]', '1'
    # 押す前に件数を見せる(確認済みの科目も外れることを、ラベルで言う)
    assert_select '#category-intel [data-pattern-suggestion=intel] label', text: /当たる4件\(うち確認済み1件\)を便覧から外します/
    # 候補の無い区分には出さない
    assert_select '#category-english [data-pattern-suggestion]', count: 0
  end

  test '候補を採用すると、外した件数を知らせる' do
    draft = draft_with_pattern_candidate

    submit_pairs(draft, browser_pairs(draft) + [['adopt_patterns[intel]', '1']])

    assert_response :see_other
    assert_match(/科目表から4件を外しました\(うち確認済み1件\)/, flash[:notice])
    document = draft.reload.document
    assert_equal ['知能4'], document['categories'].find { |category| category['key'] == 'intel' }['number_patterns']
    assert_not_includes document['courses'].pluck('number'), '知能404'
  end

  test '候補を押さずに保存すると、文書は1バイトも変わらない' do
    draft = draft_with_pattern_candidate
    before = draft.document.deep_dup

    submit_pairs(draft, browser_pairs(draft))

    assert_equal before, draft.reload.document
  end

  # ---- 指摘と決まりの箱から、内部の識別子を消す(リンク先は id のまま) ----

  # 規則に、id と別の名前を付けた文書。id が画面の文字に出れば、このテストが拾う。
  def document_with_named_rules
    document = requirements_document
    document['rules'].find { |entry| entry['id'] == 'path_rule' }['label'] = '次のどちらかの系列'
    document['rules'] << fixture_rule('rule_ge_total', 'credit_sum', categories: [], required_credits: 4,
                                                                     label: '共通教育の合計')
    document
  end

  test '指摘の一覧に、規則の名前が出て、規則の id は出ない。指摘は規則の箱にも残る' do
    show(draft(document: document_with_named_rules))

    assert_select '#requirements_findings [data-scope=rule]', text: /共通教育の合計/
    findings_text = css_select('#requirements_findings').text
    assert_not_includes findings_text, 'rule_ge_total'
    # target は id のまま。決まりの箱に付く指摘は、今までどおり id で突き合わさる
    assert_select '#rule-rule_ge_total', text: /categories\)が空/
  end

  test '指摘から、画面の該当する決まりへのリンクが残っている' do
    show(draft(document: document_with_named_rules))

    link = css_select('#requirements_findings [data-scope=rule] a[href="#rule-rule_ge_total"]')
    assert_predicate link, :any?, '指摘に、決まりへのリンクが無い'
    assert_equal '該当の箇所へ', link.first.text.strip
    # リンク先が、実際にページにある
    assert_select '#rule-rule_ge_total', 1
  end

  test '行の指摘から、その行へのリンクが残り、行の id は出ない' do
    document = requirements_document
    document['display']['groups'][0]['rows'] << fixture_row('row_ge_ghost', ['ghost'], [], 2, name: '幻の行')
    show(draft(document: document))

    item = css_select('#requirements_findings [data-scope=display]').find { |li| li.text.include?('幻の行') }
    assert_not_nil item, '行の指摘が出ていない'
    assert_not_includes item.text, 'row_ge_ghost'
    assert_not_nil item.at_css('a[href="#row-row_ge_ghost"]')
    assert_select '#row-row_ge_ghost', 1
  end

  test '決まりの箱に、規則の id が出ない' do
    document = document_with_named_rules
    document['display']['groups'][0]['rows'][0]['check_ids'] = %w[humanities path_rule]
    show(draft(document: document))

    box = css_select('#row-humanities [data-rule-box=path_rule]').first
    assert_not_nil box, '決まりの箱が出ていない'
    assert_includes box.text, '次のどちらかの系列'
    assert_not_includes box.text, 'path_rule'
  end

  test '画面の中の「#rule-」へのリンクは、どれも画面の中の箱に着く(切れたリンクを作らない)' do
    page = { 'page' => 6, 'kind' => 'requirements', 'status' => 'read', 'text' => '備考 外国人留学生の特例は別に定める。' }
    draft = draft(document: document_with_named_rules, extra_pages: [page])
    save draft, annotations: { card_id(draft, :foreign_student) => { disposition: 'credit_sum' } }
    show(draft)

    links = css_select('a[href^="#rule-"], a[href^="#row-"]').pluck('href')
    assert_operator links.size, :>=, 2, '指摘と注釈のカードからのリンクが出ていない'
    links.each { |href| assert_select "[id='#{href.delete_prefix('#')}']", 1, "#{href} の行き先が無い" }
  end

  test '注釈のカードに、足した規則の名前が出て、規則の id は出ない。リンクは残る' do
    page = { 'page' => 6, 'kind' => 'requirements', 'status' => 'read', 'text' => '備考 外国人留学生の特例は別に定める。' }
    draft = draft(extra_pages: [page])
    id = card_id(draft, :foreign_student)
    save draft, annotations: { id => { disposition: 'credit_sum' } }

    show(draft)

    card = css_select("#annotation-#{id}").first
    assert_includes card.text, '備考 外国人留学生の特例は別に定める。'
    assert_includes card.text, '足しました'
    assert_not_includes card.text.gsub('「備考 外国人留学生の特例は別に定める。」', ''), "annotation_#{id}"
    assert_not_nil card.at_css("a[href='#rule-annotation_#{id}']")
  end
end

