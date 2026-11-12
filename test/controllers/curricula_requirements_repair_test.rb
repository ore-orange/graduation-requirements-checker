# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require_relative '../support/requirements_draft_fixtures'

# 要件表の確認画面の、直す手段。入力を失わずに直せること・足りない章と行を足せること・読み違えた注記を外せること・
# 判定の数字を決める値が、読むだけで見えること。
class CurriculaRequirementsRepairTest < ActionDispatch::IntegrationTest
  include RequirementsDraftFixtures
  include RequirementsScreenHelpers

  REAL = Rails.root.join('config/curricula/intelligent_informatics/2024.json')

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
  end

  teardown do
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
  end

  def real_document = JSON.parse(REAL.read)

  # ---- 判定の数字を決める値が、開かなくても見える ----

  # 判定の数字を決める値は、読むだけでなく、その場で直せる欄に出ている。
  # 畳んだ中(「…」)に入れてはいけない。畳んだ中の誤読は、人が開かないと見つからない(設計書 項目3・7)。
  def field_in(selector, name)
    field = css_select("#{selector} [name='#{name}']").first
    assert_not_nil field, "#{name} が #{selector} にありません"
    assert_empty field.ancestors('details'), "#{name} が畳んだ中にあります"
    field
  end

  test '算入の上限・除外の接頭辞・必修の科目数・グループの分け方が、畳まずに直せる欄に出る(実物の2024年度)' do
    show(draft(document: real_document))
    index = ->(id) { css_select("#rule-#{id} input[name$='[id]']").first['name'][/\d+/] }

    assert_equal '2', field_in('#rule-natural_cap', "rules[#{index.call('natural_cap')}][credits]")['value']
    assert_equal '知能', field_in('#rule-own_fusion', "rules[#{index.call('own_fusion')}][number_prefix]")['value']
    assert_equal '', field_in('#rule-excluded_category',
                              "rules[#{index.call('excluded_category')}][number_prefix]")['value'].to_s
    assert_equal '31', field_in('#rule-required_all',
                                "rules[#{index.call('required_all')}][expected_course_count]")['value']
    assert_equal 'number_prefix', field_in('#rule-fusion_provider',
                                           "rules[#{index.call('fusion_provider')}][group_by]")['value']
  end

  # 入れ子(any_of の選択肢・one_of_paths の経路)の中身も、畳まずに繰り返しの行で出す。
  test '入れ子の選択肢の必要単位と、経路の役割が、畳まずに出る(実物の2024年度)' do
    show(draft(document: real_document))

    assert_select '#rule-foreign_language [data-rule-conditions=?]', 'foreign_language' do
      assert_select "input[value='12']"
      assert_select 'select option[selected][value=?]', 'grouped_max'
    end
    assert_select '#rule-calculus [data-rule-paths=?]', 'calculus', text: /経路1/
    assert_select '#rule-calculus input[type=checkbox][value=?][checked]', 'calculus_st_1'
    assert_select '#rule-calculus input[type=checkbox][value=?][checked]', 'calculus_intro_1'
    css_select('#rule-calculus [data-rule-paths] input[type=checkbox]').each do |box|
      assert_empty box.ancestors('details'), '経路が畳んだ中にあります'
    end
  end

  # 要確認の理由は、全学生の判定を「要確認」にし、学生の画面に出る値。人が外せること(設計書 項目7)。
  test '要確認の理由(review_note)は、決まりの「…」の欄から外せる(実物の2024年度)' do
    draft = draft(document: real_document)
    show(draft)
    index = css_select("#rule-calculus input[name$='[id]']").first['name'][/\d+/]

    note = css_select("#rule-calculus [name='rules[#{index}][review_note]']").first
    assert_match(/微分積分学の系列が混在・重複しており/, note['value'])

    save draft, rules: [{ id: 'calculus', review_note: '' }]
    assert_nil rule(draft, 'calculus')['review_note']
  end

  test '保存の宛先の URL を GET で開き直しても、404 にならず、確認画面へ戻る' do
    draft = draft()
    get "/curricula/#{draft.id}/update_rules", env: ENV_LOCAL

    assert_redirected_to "/curricula/#{draft.id}#requirements_review"
  end

  # 科目が1つも無い役割を名指しする経路は、その規則が必ず要確認になる。突き合わせが理由を言う。
  test '経路が名指しする役割に科目が1つも無ければ、そう出る' do
    document = requirements_document
    document['rules'].find { |rule| rule['id'] == 'path_rule' }['paths'] = [['no_such_role']]
    show(draft(document: document))

    assert_select '#rule-path_rule input[type=checkbox][value=?][checked]', 'no_such_role'
    assert_select '#rule-path_rule', text: /役割\(no_such_role\)を持つ科目が、科目表にありません/
  end

  test '上限と接頭辞は、欄で直せ、直すと印が付く。接頭辞を空にすると欄ごと消える' do
    draft = draft(document: real_document)
    cap = rule(draft, 'natural_cap')
    save draft, rules: [{ id: 'natural_cap', credits: '20' }, { id: 'own_fusion', number_prefix: '機械' }]

    assert_equal [20, true], rule(draft, 'natural_cap').values_at('credits', 'confirmed')
    assert_equal '機械', rule(draft, 'own_fusion')['number_prefix']
    assert_equal cap['category'], rule(draft, 'natural_cap')['category']

    save draft, rules: [{ id: 'own_fusion', number_prefix: '' }]
    assert_not rule(draft, 'own_fusion').key?('number_prefix'), '空の欄が残ると、読み込みが拒む'
    assert_nothing_raised { GraduationAssessment::Catalogue.new(draft.document) }
  end

  test '上限に数でない値は入れられない' do
    draft = draft(document: real_document)
    save draft, rules: [{ id: 'natural_cap', credits: 'ふたつ' }]

    assert_response :unprocessable_content
    assert_match(/規則「natural_cap」の算入の上限\(単位\)は数で入れてください/, response.body)
  end

  test '触らずに保存しても、上限・接頭辞の欄で何も直したことにならない(実物の文書)' do
    draft = draft(document: real_document)
    submit_pairs(draft, browser_pairs(draft))

    assert_match(/変えた箇所はありませんでした/, flash[:notice])
    assert_equal real_document, draft.reload.document
  end

  # ---- 入力を失わない ----

  def change(pairs, changes)
    pairs.map { |name, value| changes.key?(name) ? [name, changes[name]] : [name, value] }
  end

  test '1つの打ち間違いで保存できなくても、打った他の欄は残り、問題は全部、項目の下に出る' do
    draft = draft()
    changes = { 'rules[0][required_credits]' => '4単位', 'rules[1][label]' => '直した英語',
                'display[groups][0][title]' => '1. 直した共通教育', 'display[total_credits]' => 'いっぱい',
                'display[groups][1][_destroy]' => '1' }
    pairs = change(browser_pairs(draft), changes)
    pairs << ['display[groups][1][_destroy]', '1'] unless pairs.assoc('display[groups][1][_destroy]')
    submit_pairs(draft, pairs)

    assert_response :unprocessable_content
    assert_equal requirements_document, draft.reload.document, '何も保存しない'
    # 問題は2件。一度に全部出る(1つ直しては送り直す、をさせない)
    assert_select '#requirements_errors li', count: 2
    assert_select '#requirements_errors', text: /規則「humanities」の必要単位は数で入れてください/
    assert_select '#requirements_errors', text: /卒業に必要な総単位は数で入れてください/
    assert_select '#rule-humanities [role=alert]', text: /4単位/
    assert_select '#total_credits_row [role=alert]', text: /いっぱい/
    # 打った値が、そのまま残る(数でない値も、他の欄も、消す印も)
    assert_select 'input[name=?][value=?]', 'rules[0][required_credits]', '4単位'
    assert_select 'input[name=?][value=?]', 'rules[1][label]', '直した英語'
    assert_select 'input[name=?][value=?]', 'display[groups][0][title]', '1. 直した共通教育'
    assert_select 'input[name=?][value=?]', 'display[total_credits]', 'いっぱい'
    assert_select 'input[type=checkbox][name=?][checked]', 'display[groups][1][_destroy]'
    assert_select 'input[type=checkbox][name=?][checked]', 'display[groups][0][_destroy]', count: 0
    # 変えた項目と問題のある項目は、開いたまま見せる
    assert_select '#rule-humanities details[open]'
    assert_select '#rule-english details[open]'
    # 章・行の値そのものは畳まないので、打った値はそのまま出ている(上のとおり)。
    # 畳むのは「…」の中の、判定の数字を決めない値だけ。値を変えた項目は、その「…」も開いたまま見せる。
    assert_select '#group-common > div > details[open]'
    # 触っていない項目の「…」は開かない
    assert_select '#rule-core details[open]', count: 0
  end

  test '保存できなかったとき、チェックの箱・注釈の選択も、送ったとおりに残る' do
    draft = draft()
    changes = { 'rules[0][required_credits]' => '4単位' }
    pairs = change(browser_pairs(draft), changes).reject do |name, value|
      name == 'rules[0][categories][]' && value == 'humanities'
    end
    pairs << ['rules[0][categories][]', 'english']
    submit_pairs(draft, pairs)

    assert_response :unprocessable_content
    assert_select 'input[name=?][value=?]', 'rules[0][required_credits]', '4単位'
    assert_select 'input[type=checkbox][name=?][value=english][checked]', 'rules[0][categories][]'
    assert_select 'input[type=checkbox][name=?][value=humanities][checked]', 'rules[0][categories][]', count: 0
  end

  test '保存できたあとの画面は、送った入力ではなく、保存した中身を出す' do
    draft = draft()
    submit_pairs(draft, change(browser_pairs(draft), 'rules[0][required_credits]' => '5'))
    assert_redirected_to curriculum_path(draft, anchor: 'requirements_review')
    follow_redirect!

    assert_select 'input[name=?][value=?]', 'rules[0][required_credits]', '5'
    assert_select '#requirements_errors', count: 0
  end

  test '古い画面からの保存は、入力を引き継がず、いまの中身で開き直す' do
    draft = draft()
    stale = revision_of(draft)
    late = fixture_rule('late', 'credit_sum', categories: ['english'], required_credits: 1)
    draft.update!(document: draft.document.merge('rules' => draft.document['rules'] + [late]))
    params = { revision: stale, rules: [{ id: 'humanities', required_credits: '9' }] }
    patch update_rules_curriculum_path(draft), params: params, env: ENV_LOCAL

    assert_redirected_to curriculum_path(draft, anchor: 'requirements_review')
    assert_match(/開いたあとに、要件表の中身が変わっています/, flash[:alert])
  end

  # ---- 章と行を足す ----

  test '章を足せる。足した章には印が付き、id は自動で付く' do
    draft = draft()
    save draft, new_group: { title: '4. 教職科目', required_credits: '20', check_id: '', id: '' }

    added = groups(draft).last
    assert_equal ['4. 教職科目', 20, [], true], added.values_at('title', 'required_credits', 'rows', 'confirmed')
    assert_equal 'added_group_1', added['id']
    assert_not added.key?('check_id')
    assert_nothing_raised { GraduationAssessment::Catalogue.new(draft.document) }
  end

  test '空の組は足さない(画面は毎回、空の「足す」欄を送る)' do
    draft = draft()
    save draft, new_group: { title: '', required_credits: '', check_id: '', id: '' },
                new_row: { group_id: '', name: '', required_credits: '', required_label: '', id: '' }

    assert_match(/変えた箇所はありませんでした/, flash[:notice])
    assert_equal 3, groups(draft).size
  end

  test '章は、名前と必要単位が無ければ足さず、id の重複も断る' do
    draft = draft()
    save draft, new_group: { title: '', required_credits: '3' }
    assert_match(/足す章の名前を入れてください/, response.body)
    save draft, new_group: { title: 'x', required_credits: 'さん' }
    assert_response :unprocessable_content
    save draft, new_group: { title: 'x', required_credits: '3', id: 'common' }
    assert_match(/章の id「common」はすでにあります/, response.body)
    assert_equal 3, groups(draft).size
  end

  test '行を足せる。章の中に入り、足した行を含む章は読み直しから守られる' do
    draft = draft()
    save draft, new_row: { group_id: 'elective', name: '専門科目(自由)', required_credits: '', required_label: '内数11単位枠',
                           categories: ['fusion', ''], check_ids: 'fusion_provider', id: '' }

    row = group(draft, 'elective')['rows'].last
    assert_equal ['専門科目(自由)', nil, '内数11単位枠', %w[fusion], %w[fusion_provider], true],
                 row.values_at('name', 'required_credits', 'required_label', 'categories', 'check_ids', 'confirmed')
    assert_equal 'added_row_1', row['id']
    assert CurriculumImport::DraftMerge::Withdrawal.human_edited?(group(draft, 'elective'))
    assert_nothing_raised { GraduationAssessment::Catalogue.new(draft.document) }
  end

  test '行は、章を選び、名前を入れ、必要単位か表示の文を入れないと足せない' do
    draft = draft()
    save draft, new_row: { group_id: '', name: '行' }
    assert_match(/行を足す章を選んでください/, response.body)
    save draft, new_row: { group_id: 'common', name: '', required_label: 'x', id: 'y' }
    assert_match(/足す行の名前を入れてください/, response.body)
    save draft, new_row: { group_id: 'common', name: '行', required_credits: '' }
    assert_match(/必要単位を数で入れるか、必要単位が空のときの表示/, response.body)
    save draft, new_row: { group_id: 'common', name: '行', required_credits: '2', id: 'english' }
    assert_match(/行の id「english」はすでにあります/, response.body)
    assert_equal 2, group(draft, 'common')['rows'].size
  end

  test '消した章の id を足し直すと、消した記録は外れる(人が戻した)' do
    draft = draft()
    save draft, display: { groups: [{ id: 'elective', _destroy: '1' }] }
    assert_equal 1, draft.reload.document['removed_by_human'].size
    save draft, new_group: { title: '3. 選択', required_credits: '4', id: 'elective' }

    assert_empty draft.reload.document['removed_by_human']
    assert_equal 'elective', groups(draft).last['id']
  end

  test '章を足すフォームと行を足すフォームが、画面に出る' do
    show(draft)

    # 畳まずに、最初から見えている(開かないと気づかない入口にしない)
    assert_select '#requirements_additions input[name=?]', 'new_group[title]'
    assert_select '#requirements_additions input[name=?]', 'new_row[name]'
    assert_select 'select[name=?] option', 'new_row[group_id]', count: 4
    css_select('#requirements_additions input[name^=new_]').each do |field|
      assert_empty field.ancestors('details'), "#{field['name']} が畳んだ中にあります"
    end
    # 規則の id は打たせない(設計書 項目5)
    assert_select '#requirements_additions input[name=?]', 'new_row[check_ids]', count: 0
    assert_select '#requirements_additions input[name=?]', 'new_group[check_id]', count: 0
  end

  # ---- 承認の注記を外す ----

  def approval_document
    document = requirements_document
    document['approval_notes'] = [{ 'scope' => 'category', 'category' => 'fusion', 'text' => '他学部の科目は承認が必要',
                                    'source_page' => 'PDF2ページ' }]
    CurriculumImport::ApprovalNotes.apply(document)
    document
  end

  test '承認の注記を外すと、その注記で付けた関門が戻り、AI が行から読んだ関門は残る' do
    document = approval_document
    document['courses'].find { |course| course['number'] == '機械991' }.delete('approval_by_note')
    document['courses'].find { |course| course['number'] == '人101' }['requires_approval'] = true
    draft = draft(document: document)
    id = card_id(draft, :approval_applied)
    save draft, remove_approval_note: id

    courses = draft.reload.document['courses'].to_h { |course| [course['number'], course['requires_approval']] }
    assert_equal false, courses['機械992'], '注記で付けた関門は戻る'
    assert_equal true, courses['機械991'], '印の無い(注記で付けたか分からない)関門は戻さない'
    assert_equal true, courses['人101'], 'AI が行から読んだ関門は残る'
    assert_nil draft.document['approval_notes']
    assert_equal ['approval_note'], draft.document['removed_by_human'].pluck('kind')
    warning = CurriculumImport::RereadWarning.for(draft.document, draft.pages.find { |page| page['page'] == 2 })
    assert_includes warning, '承認の注記(区分「fusion」)'
  end

  test '外した承認の注記は、同じページを読み直しても戻らない' do
    draft = draft(document: approval_document)
    FileUtils.mkdir_p(draft.images_dir)
    File.binwrite(draft.images_dir.join('p2.png'), "\x89PNG".b)
    save draft, remove_approval_note: card_id(draft, :approval_applied)

    answer = { 'categories' => draft.document['categories'], 'roles' => [], 'rules' => draft.document['rules'],
               'display' => { 'groups' => [{ 'id' => 'g', 'title' => 'g', 'required_credits' => 1, 'rows' => [
                 { 'id' => 'r', 'name' => '他学部の科目は承認が必要', 'required_credits' => 1, 'categories' => ['fusion'],
                   'check_ids' => [], 'credits_from_check' => false }
               ] }] } }
    reader = Class.new { define_method(:read_requirements) { |**| answer } }.new
    CurriculumReader.stub(:available?, true) do
      CurriculumReader.stub(:new, reader) do
        post read_page_curriculum_path(draft, page: 2), headers: { 'Accept' => 'text/vnd.turbo-stream.html' },
                                                        env: ENV_LOCAL
      end
    end

    assert_nil draft.reload.document['approval_notes'], '読み直しが、外した注記を戻した'
    assert(draft.document['courses'].none? { |course| course['requires_approval'] })
  ensure
    FileUtils.rm_rf(draft.images_dir) if draft
  end

  test '承認の注記を外すと、その注記から決めた扱いは白紙に戻り、もう一度決められる' do
    warning = CurriculumImport::ApprovalNotes.unresolved_warning('他学部の科目は承認が必要')
    page = { 'page' => 5, 'kind' => 'requirements', 'status' => 'read', 'text' => '', 'warnings' => [warning] }
    draft = draft(extra_pages: [page])
    unattached = card_id(draft, :approval_unattached)
    save draft, annotations: { unattached => { disposition: 'approval', category: 'fusion' } }
    save draft, remove_approval_note: card_id(draft, :approval_applied)

    assert_nil draft.reload.document['annotation_decisions']
    show(draft)
    assert_select "#annotation-#{unattached} select[name*=disposition]"
  end

  test '足した規則を消すと、注釈のカードは、もう一度決められる' do
    page = { 'page' => 6, 'kind' => 'requirements', 'status' => 'read', 'text' => '備考 外国人留学生の特例は別に定める。' }
    draft = draft(extra_pages: [page])
    id = card_id(draft, :foreign_student)
    save draft, annotations: { id => { disposition: 'credit_sum' } }
    show(draft)
    assert_select "#annotation-#{id} select", count: 0

    save draft, rules: [{ id: "annotation_#{id}", _destroy: '1' }]
    show(draft)
    assert_select "#annotation-#{id} select[name*=disposition]"
    assert_select "#annotation-#{id}", text: /いまは残っていません/

    save draft, annotations: { id => { disposition: 'ignore' } }
    assert_equal 'ignore', draft.reload.document['annotation_decisions'][id]['disposition']
  end

  test '注釈の扱いを選ばずに送ると、黙って捨てずに、そのカードの問題として出す' do
    page = { 'page' => 6, 'kind' => 'requirements', 'status' => 'read', 'text' => '備考 外国人留学生の特例は別に定める。' }
    draft = draft(extra_pages: [page])
    id = card_id(draft, :foreign_student)
    save draft, annotations: { id => { disposition: '' } }

    assert_response :unprocessable_content
    assert_select "#annotation-#{id} [role=alert]", text: /注釈の扱いを選んでください/
    save draft, annotations: { id => 'こわれた' }
    assert_match(/注釈の扱いを選んでください/, response.body)
  end
end

