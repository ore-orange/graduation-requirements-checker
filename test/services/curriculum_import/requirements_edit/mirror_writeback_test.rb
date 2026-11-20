# frozen_string_literal: true

require 'test_helper'
require_relative '../../../support/requirements_draft_fixtures'

# 持ち主(行・章・枠・総単位の枠)の欄を直したとき、その持ち主が隠している決まりにも同じ値を書く(設計書 項目2)。
#
# これは落とし穴を埋める変更。display.rows[].required_credits は学生の画面に出す数字で、
# 判定は rules[].required_credits を見る。だから「情報技術系 2単位」を3に直して保存しても、
# いままでは学生の判定が2単位のままだった。両方を直さないといけないのに、画面はそれを教えてくれない。
#
# 書き戻すのは、持ち主と同じことを言っている決まり(RequirementsReview::Mirror)だけ。
# 食い違っていて箱が出ている決まりは、人がその箱で直すので、触らない。
class MirrorWritebackTest < ActiveSupport::TestCase
  include RequirementsDraftFixtures

  setup do
    @curriculum = Curriculum.create!(slug: 'mirror_writeback', admission_year: 2025, faculty_name: '工学部',
                                     department_name: '工学科 知能情報コース', source_filename: 'handbook.pdf',
                                     pages: [], document: requirements_document)
  end

  def edit(**params)
    revision = CurriculumImport::RequirementsEdit.revision(@curriculum.document)
    CurriculumImport::RequirementsEdit.new(@curriculum, { revision: revision }.merge(params)).call
  end

  def document_after = @curriculum.reload.document

  def rule_after(id) = document_after['rules'].find { |rule| rule['id'] == id }

  # 行 humanities(4単位・区分 humanities)が、同じことを言う規則 humanities を隠している。
  def row_param(**fields) = { groups: { '0' => { id: 'common', rows: { '0' => { id: 'humanities', **fields } } } } }

  def confirmed?(item) = item[CurriculumImport::DraftMerge::CONFIRMED] == true

  # ---- 書き戻す ----

  test '行の必要単位を直すと、隠れている決まりの必要単位も直る' do
    result = edit(display: row_param(required_credits: '6'))

    assert_predicate result, :ok?
    assert_equal 6, rule_after('humanities')['required_credits']
    assert confirmed?(rule_after('humanities')), '書き戻した決まりにも、人が確認した印が付く'
  end

  test '行の区分を直すと、隠れている決まりの区分も直る' do
    edit(display: row_param(categories: %w[humanities english]))

    assert_equal %w[humanities english], rule_after('humanities')['categories']
  end

  # 行の区分が変わると、その行を含む章の「中の行の区分の合併」も変わる。波及させないと、
  # 章が隠している決まりが古い区分を数え続け、それが画面のどこにも出ない(落とし穴が形を変えて残る)。
  test '行の区分を直すと、その行を含む章が隠している決まりの区分も直る' do
    document = requirements_document
    document['display']['groups'][0]['check_id'] = 'group_total'
    document['rules'] << fixture_rule('group_total', 'credit_sum', categories: %w[humanities english],
                                                                   required_credits: 6)
    @curriculum.update!(document: document)

    edit(display: row_param(categories: %w[humanities fusion]))

    assert_equal %w[humanities fusion english].sort, rule_after('group_total')['categories'].sort
  end

  test '総単位を直すと、総単位の決まりの必要単位も直る' do
    edit(display: { total_credits: '20' })

    assert_equal 20, rule_after('total')['required_credits']
  end

  # ---- 触らない ----

  # 既存の不変条件。画面を開いて何も変えずに保存したら、文書は1バイトも変わらない。
  test '触らずに保存しても、文書は1バイトも変わらない' do
    before = @curriculum.document.deep_dup

    edit(display: row_param(required_credits: '4', categories: ['humanities']))

    assert_equal before, document_after
  end

  # 実データには、同じ区分を違う並びで持つ決まりがある(行は 人文・社会・自然・総合…、
  # 決まりは 人文・社会・総合…・自然)。並びが違うだけで書き換えると、この不変条件が壊れる。
  test '区分の並びが違うだけなら、書き換えない' do
    document = requirements_document
    document['display']['groups'][0]['rows'][0]['categories'] = %w[humanities english]
    document['rules'].find { |rule| rule['id'] == 'humanities' }['categories'] = %w[english humanities]
    @curriculum.update!(document: document)
    before = @curriculum.document.deep_dup

    edit(display: row_param(categories: %w[humanities english]))

    assert_equal before, document_after
  end

  # 2 と 2.0 は同じ単位。書き換えると、触っていない文書が変わる。
  test '同じ単位を違う書き方で持っていても、書き換えない' do
    document = requirements_document
    document['rules'].find { |rule| rule['id'] == 'humanities' }['required_credits'] = 4.0
    @curriculum.update!(document: document)
    before = @curriculum.document.deep_dup

    edit(display: row_param(required_credits: '4'))

    assert_equal before, document_after
  end

  # 食い違っている決まりは箱が出ている。人がその箱で直すので、行の値で上書きしない。
  test '箱が出ている決まりには、書き戻さない' do
    document = requirements_document
    document['rules'].find { |rule| rule['id'] == 'humanities' }['required_credits'] = 6
    @curriculum.update!(document: document)

    edit(display: row_param(required_credits: '8'))

    assert_equal 6, rule_after('humanities')['required_credits']
    assert_equal 8, document_after['display']['groups'][0]['rows'][0]['required_credits']
  end

  # 同じ保存の中で決まりそのものも送られていたら(箱が出ていたということ)、そちらを優先する。
  test '同じ保存で決まりの箱も直していたら、そちらを優先する' do
    edit(display: row_param(required_credits: '6'),
         rules: { '0' => { id: 'humanities', required_credits: '9' } })

    assert_equal 9, rule_after('humanities')['required_credits']
  end

  # 隠した決まりの名前と説明は、持ち主の「…」から送られる(設計書 項目2-2)。
  # それを直したからといって書き戻しを止めると、行の必要単位がどこにも書かれない。
  # そのとき判定の数字は画面のどこにも出ていないので、人は食い違いに気づけない。
  test '隠した決まりの名前を一緒に直しても、必要単位は書き戻す' do
    edit(display: row_param(required_credits: '6'),
         rules: { '0' => { id: 'humanities', label: '直した名前' } })

    assert_equal 6, rule_after('humanities')['required_credits'], '名前を直すと書き戻しが止まっていた'
    assert_equal '直した名前', rule_after('humanities')['label']
  end

  # 箱が出ている決まりは、人がその欄で直す。送信にその欄が入っているかで見分ける
  # (画面が箱を出したなら、ブラウザは必ずその欄を送る)。
  test '送信に判定の欄が入っている決まりには、書き戻さない' do
    edit(display: row_param(required_credits: '9'),
         rules: { '0' => { id: 'humanities', required_credits: '4', categories: ['humanities'] } })

    assert_equal 4, rule_after('humanities')['required_credits'], '画面に出ていた値を上書きした'
  end

  # ---- 壊れた送信でも落ちない ----

  # 行を消すと、その行だけが指していた決まりも drop_orphaned_rules が消す。
  # 書き戻しが、消えた持ち主の値を消えた決まりに書こうとして落ちてはいけない。
  test '行を消した保存でも、書き戻しが落ちない' do
    result = edit(display: row_param(_destroy: '1'))

    assert_predicate result, :ok?
    assert_nil rule_after('humanities')
    assert_nil(document_after['display']['groups'][0]['rows'].find { |row| row['id'] == 'humanities' })
  end

  # ---- 実物の便覧で、落とし穴が埋まっていること ----
  #
  # これが、この作り直しでいちばん大事な一本。2024年度の実データで、行「情報技術系」の必要単位を
  # 2 → 3 に直したとき、判定が見る数字(規則 required_information)も3になること。
  # いままでは行の数字だけが変わり、学生の判定は2単位のままだった。
  test '実物の便覧で、行の必要単位を直すと判定が見る数字も変わる' do
    real = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    @curriculum.update!(document: real)
    assert_equal 2, rule_after('required_information')['required_credits'], '前提: 判定は2単位を見ている'

    result = edit(display: { groups: { '2' => { id: 'required',
                                                rows: { '0' => { id: 'required_information',
                                                                 required_credits: '3' } } } } })

    assert_predicate result, :ok?
    row = document_after['display']['groups'].flat_map { |group| group['rows'].to_a }
                                             .find { |item| item['id'] == 'required_information' }
    assert_equal 3, row['required_credits'], '行に出る数字'
    assert_equal 3, rule_after('required_information')['required_credits'], '判定が見る数字'
  end

  # 区分が空の credit_sum は何も数えない。行を空にしたなら、隠れている決まりも空にする
  # (古い区分を黙って数え続けさせない)。
  test '行の区分を空にすると、隠れている決まりの区分も空になる' do
    edit(display: row_param(categories: ['']))

    assert_empty Array(rule_after('humanities')['categories'])
  end
end

