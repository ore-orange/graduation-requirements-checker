# frozen_string_literal: true

require 'test_helper'
require_relative '../support/requirements_draft_fixtures'

# 科目表の確認画面。AI が読んだ科目を、人が PDF と見比べて直す場所。
# 見せること(誤読が見える・単位を水増しする値が行に出る)と、直した値が1科目ずつ保存され、読み直しから守られることを確かめる。
class CurriculaCoursesReviewTest < ActionDispatch::IntegrationTest
  include RequirementsDraftFixtures
  include RequirementsScreenHelpers

  STREAM = { 'Accept' => 'text/vnd.turbo-stream.html' }.freeze

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
  end

  teardown do
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
    Curriculum.find_each { |curriculum| FileUtils.rm_rf(curriculum.images_dir) }
  end

  # 幅(横)だけが読める PNG の見出し。PDFペインの倍率の元になる。
  def png_header(width) = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR".b + [width, 100].pack('N2')

  # 科目表のページ(3)も読み終えた下書き。ページ画像も置く。
  def course_draft(document: requirements_document, images: [3])
    page = { 'page' => 3, 'kind' => 'courses', 'status' => 'read', 'error' => nil, 'text' => '科目',
             'contributed' => contributed_courses(document) }
    record = draft(document: document, extra_pages: [page])
    FileUtils.mkdir_p(record.images_dir)
    images.each { |number| File.binwrite(record.images_dir.join("p#{number}.png"), png_header(1200)) }
    record
  end

  def contributed_courses(document) = { 'courses' => document['courses'].pluck('key') }

  def course_in(draft, number) = draft.reload.document['courses'].find { |course| course['number'] == number }

  def confirmed?(draft, number) = course_in(draft, number)['confirmed'] == true

  def update_course(draft, headers: {}, **params)
    patch update_courses_curriculum_path(draft), params: params, headers: headers, env: ENV_LOCAL
  end

  # 番号帯の他の科目(知能101〜104)と区分が違う1科目(知能105)を持つ文書。
  def mismatch_document
    document = requirements_document
    numbered = (101..104).map { |n| fixture_course("知能#{n}", "科目#{n}", 'required_core', required: true) }
    others = fixture_courses.reject { |course| course['number'].start_with?('知能') }
    document['courses'] = numbered + [fixture_course('知能105', '食い違う科目', 'fusion')] + others
    document
  end

  # Turbo Stream の応答の、各 turbo-stream 要素。
  def streams_of(response) = Nokogiri::HTML5.fragment(response.body).css('turbo-stream')

  def rows
    css_select('#course-review tbody[id^="course-"]:not([id^="course-category-"]):not(#course-first-look)')
  end

  # ---- 見せる ----

  test '区分ごとにまとめて出す' do
    show(course_draft)

    assert_response :success
    assert_select '#course-review h4', text: /人文系 ・ 3科目 ・ 必修0単位/
    assert_select '#course-review h4', text: /コア必修 ・ 2科目 ・ 必修4単位/
    assert_select '#course-review h4', text: /算入対象外 ・ 1科目 ・ 必修0単位/
  end

  test '科目はすべて1回ずつ出る(最初に見る科目も、区分の節と二重に出ない)' do
    document = mismatch_document
    show(course_draft(document: document))

    numbers = rows.map { |row| row.at_css('td.tabular-nums').text.squish.split.first }

    assert_equal document['courses'].pluck('number').sort, numbers.sort
  end

  test '推定と食い違う科目を先頭に出し、AIの誤りと決まったわけではないと言う' do
    show(course_draft(document: mismatch_document))

    assert_select '#course-review tr:first-child', text: /知能105/
    assert_select '#course-first-look h4', text: /最初に見る科目 ・ 1科目/
    assert_equal '知能105', rows.first.at_css('td.tabular-nums').text.squish.split.first
    assert_select '#course-first-look', text: /AIの誤りと決まったわけではありません/
    assert_select '#course-review', text: /番号帯の他の科目は「コア必修」/
    assert_select '#course-review button[formaction*="category=required_core"]', text: '推定の区分にする'
    # 区分の節の見出しは、先頭の節に出した科目も数える
    assert_select '#course-review h4', text: /工学融合 ・ 3科目/
    assert_select '#course-category-fusion th', text: /うち1科目は、上の「最初に見る科目」にあります/
  end

  test '確認済みにした食い違いは、先頭の節から外れて区分の節に戻る' do
    document = mismatch_document
    document['courses'].find { |course| course['number'] == '知能105' }['confirmed'] = true
    show(course_draft(document: document))

    assert_select '#course-first-look', count: 0
    assert_select '#course-review tbody#course-category-fusion ~ tbody tr', text: /知能105/
  end

  test '区分が便覧に無い科目は、公開を止める指摘つきで先頭に出て、確認しても先頭に残る' do
    document = requirements_document
    document['courses'][0]['category'] = 'vanished'
    document['courses'][0]['confirmed'] = true
    show(course_draft(document: document))

    assert_equal '人101', rows.first.at_css('td.tabular-nums').text.squish.split.first
    assert_select '#course-first-look h4', text: /最初に見る科目 ・ 1科目/
    assert_select '#course-review .cr-bad', text: /区分が便覧に無い: vanished/
    assert_select '#course-review .border-rose-200', text: /公開を止める.*区分「vanished」が categories にありません/
    assert_select '#courses_summary', text: /公開を止める指摘が付いた科目が1件/
  end

  test '突き合わせの指摘は、その科目の行の下に出る(重複した番号は、どちらの行にも)' do
    document = requirements_document
    document['courses'] << fixture_course('人101', '別の行', 'humanities').merge('key' => 'dup_key')
    show(course_draft(document: document))

    assert_equal(2, css_select('#course-review p').count { |note| note.text.match?(/同じ科目番号「人101」の科目が2件/) })
  end

  test '判定の単位を水増しする値は、開かなくても行に出る' do
    document = requirements_document
    document['courses'][0].merge!('credits' => 3, 'requires_approval' => true, 'selectable' => false)
    show(course_draft(document: document))

    row = css_select('#course-review tbody[id="course-course_人101"]').first.text.squish

    assert_includes row, '人101'
    assert_includes row, '3'
    assert_includes row, '人文系'
    assert_includes row, '選べない'
    assert_includes row, '承認が必要'
    assert_select '#course-course_情01 .cr-bad', text: '総単位に数えない'
    assert_select '#course-category-excluded .cr-bad', text: '総単位に数えない'
    # 単位が読めていない科目は、読めていないと赤で出す(空欄にしない)
    bad = requirements_document.tap { |doc| doc['courses'][1]['credits'] = nil }
    show(course_draft(document: bad))
    assert_select '#course-course_人102 .cr-bad', text: '読めない'
  end

  test '選べる科目と選べない科目は、見出しの数と行の色で違いが分かる。AIは全部を選べると読むと断る' do
    show(course_draft)

    assert_select '#course-review', text: /AI は、すべての科目を「学生が選べる」と読みます/
    assert_select '#course-category-excluded .cr-bad', text: '選べない1'
    assert_select '#course-category-humanities .cr-muted', text: '選べる3'
    assert_select '#course-course_情01.bg-rose-50\/60'
    assert_select '#course-course_情01 td button.cr-btn-bad', text: '選べない'
    assert_select '#course-course_人101 td button:not(.cr-btn-bad)', text: '選べる'
  end

  test '科目表が読まれていない下書きは、読み取りを促すだけで、表を出さない' do
    unread = Curriculum.create!(slug: 'y', admission_year: 2025, faculty_name: '工学部', department_name: 'コース',
                                source_filename: 'h.pdf',
                                pages: [{ 'page' => 1, 'kind' => 'skip', 'status' => 'pending' }])
    show(unread)

    assert_response :success
    assert_select '#course-review', text: /まだ科目表を読み取っていません/
    assert_select '#course-review table', count: 0
    assert_select '#course_action_form', count: 0
  end

  test 'PDFのページを並べて見られる。ペインに出るのは科目表のページだけで、行から飛べる' do
    show(course_draft(images: [1, 2, 3]))

    assert_select 'img[src*="page_image"]', count: 1
    assert_select %(img[src="#{page_image_curriculum_path(Curriculum.last, 3)}"])
    assert_select '#pdf-pane-row [data-action="pdf-pane#fit"]', text: '幅に合わせる'
    assert_select '#pdf-pane-row [data-action="pdf-pane#zoomIn"]'
    assert_select '#course-review table[data-controller="pdf-pane"][data-pdf-pane-page-width-value="1200"]'
    assert_select '#course-course_人101 button[data-action="pdf-pane#jump"][data-page="1"]', text: '3頁'
  end

  test '画像が無い下書きでも、ペインを出さずに画面は開ける' do
    show(course_draft(images: []))

    assert_response :success
    assert_select 'img[src*="page_image"]', count: 0
    assert_select '#pdf-pane-row', count: 0
    assert_select '#course-course_人101 td', text: /PDF3ページ/
  end

  test '保存のフォームは update_courses に向く。確認・直す・足すは、そこへ送る' do
    draft = course_draft
    show(draft)

    assert_select 'form[action=?]', update_courses_curriculum_path(draft)
    assert_select '#course_action_form[action=?]', update_courses_curriculum_path(draft)
    assert_select %(#courses_add form[action="#{update_courses_curriculum_path(draft)}"]) do
      assert_select 'input[name=added_by_hand]'
      assert_select 'select[name=category] option', text: '人文系'
    end
    assert_select %(#course-course_人101 button[form=course_action_form][formaction*="confirmed=true"])
    assert_select %(#course-course_人101 a[href="#{edit_course_curriculum_path(draft, key: 'course_人101')}"])
  end

  test '公開済みの便覧では、科目の保存も編集欄も開けない' do
    published = Curriculum.published.first

    patch update_courses_curriculum_path(published), params: { number: '知能101', confirmed: true }, env: ENV_LOCAL
    assert_redirected_to requirements_path
    get edit_course_curriculum_path(published, key: 'x'), env: ENV_LOCAL
    assert_redirected_to requirements_path
  end

  test 'ローカル以外からは、科目の保存も編集欄も開けない' do
    draft = course_draft

    patch update_courses_curriculum_path(draft), params: { number: '人101', confirmed: true },
                                                 env: { 'REMOTE_ADDR' => '203.0.113.9' }
    assert_response :not_found
    assert_not confirmed?(draft, '人101')
  end

  # ---- 保存する ----

  test '確認チェックは1科目ずつ保存する' do
    draft = course_draft

    update_course(draft, number: '人101', confirmed: true)

    assert confirmed?(draft.reload, '人101')
    assert_not confirmed?(draft, '人102')
    assert_redirected_to curriculum_path(draft, anchor: 'course-course_人101')
  end

  test '同時に別の科目を確認しても取りこぼさない' do
    draft = course_draft

    update_course(draft, number: '人101', confirmed: true)
    update_course(draft, number: '人102', confirmed: true)

    assert confirmed?(draft.reload, '人101')
    assert confirmed?(draft, '人102')
  end

  test '保存は document 全体を書き戻さず、その科目の位置だけを jsonb_set で更新する' do
    draft = course_draft
    # 古い画面(読み込み済みの draft)を使う別の経路が、あとから別の科目を確認していても、取りこぼさないこと
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| statements << payload[:sql] }

    update_course(draft, number: '人101', confirmed: true)

    ActiveSupport::Notifications.unsubscribe(subscriber)
    updates = statements.grep(/\AUPDATE "curricula"/)
    assert(updates.any? { |sql| sql.include?('jsonb_set(document') }, updates.inspect)
    assert(updates.none? { |sql| sql.include?('SET "document" =') }, "document 全体を書いた: #{updates.inspect}")
  end

  test '1科目の保存は、ほかの科目・規則・ページの記録に触れない' do
    draft = course_draft
    before = draft.document.except('courses')
    others = draft.document['courses'].reject { |course| course['number'] == '人101' }
    pages = draft.pages

    update_course(draft, key: 'course_人101', credits: '4')

    draft.reload
    assert_equal 4, course_in(draft, '人101')['credits']
    assert_equal before, draft.document.except('courses')
    assert_equal(others, draft.document['courses'].reject { |course| course['number'] == '人101' })
    assert_equal pages, draft.pages
  end

  test '読み落とした科目を手で足せる' do
    draft = course_draft

    update_course(draft, number: '知能999', name: '追加', credits: 2, category: 'fusion', added_by_hand: true)

    added = draft.reload.document['courses'].select { |course| course['added_by_hand'] }
    assert_equal 1, added.size
    expected = { 'number' => '知能999', 'name' => '追加', 'credits' => 2, 'category' => 'fusion', 'confirmed' => true,
                 'selectable' => true, 'requires_approval' => false, 'required' => false, 'key' => 'course_知能999' }
    assert_equal expected, added.first.slice(*expected.keys)
    assert_redirected_to curriculum_path(draft, anchor: 'course-course_知能999')
    show(draft)
    assert_select '#course-course_知能999', text: /手で足した/
  end

  test '足せない科目(同じ番号・便覧に無い区分・空の欄)は、何も足さず、入力を残して理由を言う' do
    draft = course_draft

    update_course(draft, number: '人101', name: '重複', credits: '2', category: 'fusion', added_by_hand: '1')
    assert_response :unprocessable_content
    assert_select '#courses_errors', text: /科目番号「人101」の科目は、すでにあります/
    assert_select %(#courses_add input[name=name][value="重複"])
    assert_select '#courses_add[open]'

    update_course(draft, number: '知能999', name: '追加', credits: '2', category: 'vanished', added_by_hand: '1')
    assert_select '#courses_errors', text: /区分「vanished」は、この便覧の区分にありません/

    update_course(draft, number: '', name: '', credits: '', category: '', added_by_hand: '1')
    assert_select '#courses_errors li', count: 4

    assert_equal 10, draft.reload.document['courses'].size
  end

  test '直せない入力は、何も保存せず422で、打った値を残し、問題を上とその科目の下に出す' do
    draft = course_draft

    update_course(draft, key: 'course_人101', name: '直した名前', credits: '4単位', category: 'fusion')

    assert_response :unprocessable_content
    assert_select '#courses_errors', text: /人101「哲学」の単位は数で入れてください\(入れた値: 4単位\)/
    assert_select '#course-course_人101 p[role=alert]', text: /入力を直してください: .*4単位/
    assert_select %(#course-edit-course_人101 input[name=credits][value="4単位"])
    assert_select %(#course-edit-course_人101 input[name=name][value="直した名前"])
    assert_select '#course-edit-course_人101 select[name=category] option[selected][value=fusion]'
    assert_select '#course-edit-course_人102', count: 0
    assert_equal 2, course_in(draft, '人101')['credits']
    assert_equal '哲学', course_in(draft, '人101')['name']
    assert_not confirmed?(draft, '人101')
  end

  test '保存できなかった入力は、チェックの箱の状態も残す(編集欄も、足す欄も)' do
    draft = course_draft

    update_course(draft, key: 'course_人101', credits: 'x', selectable: '0', requires_approval: '1', required: '1')

    assert_select '#course-edit-course_人101 input[type=checkbox][name=selectable][checked]', count: 0
    assert_select '#course-edit-course_人101 input[type=checkbox][name=requires_approval][checked]'
    assert_select '#course-edit-course_人101 input[type=checkbox][name=required][checked]'

    update_course(draft, number: '知能999', name: '追加', credits: 'x', category: 'fusion', added_by_hand: '1',
                         selectable: '0', requires_approval: '1')

    assert_select '#courses_add input[type=checkbox][name=selectable][checked]', count: 0
    assert_select '#courses_add input[type=checkbox][name=requires_approval][checked]'
    assert_select '#courses_add select[name=category] option[selected][value=fusion]'
  end

  test 'AIが要確認とした科目は最初に見る科目に出る。確認すると外れる' do
    document = requirements_document
    document['courses'][2]['review_reason'] = '単位が読み取れない'
    draft = course_draft(document: document)

    show(draft)
    assert_select '#course-first-look h4', text: /最初に見る科目 ・ 1科目/
    assert_select '#course-course_人103', text: /AIの要確認: 単位が読み取れない/
    assert_equal '人103', rows.first.at_css('td.tabular-nums').text.squish.split.first

    update_course(draft, number: '人103', confirmed: true)
    show(draft)
    assert_select '#course-first-look', count: 0
    assert_select '#course-course_人103', text: /AIの要確認: 単位が読み取れない/
  end

  test '単位が0〜20の数でない・名前が空・区分が便覧に無い入力は、全部まとめて断る' do
    draft = course_draft

    update_course(draft, key: 'course_人101', name: ' ', credits: '99', category: 'vanished')

    assert_response :unprocessable_content
    assert_select '#courses_errors li', count: 3
    assert_select '#courses_errors', text: /科目名を入れてください/
    assert_select '#courses_errors', text: /単位は0〜20/
    assert_select '#courses_errors', text: /区分「vanished」は、この便覧の区分にありません/
  end

  test '全角の数字と空白を整えて保存し、直した科目は確認済みになる' do
    draft = course_draft

    update_course(draft, key: 'course_人101', number: ' 人１０９ ', credits: '１.５')

    course = course_in(draft, '人109')
    assert_equal 1.5, course['credits']
    assert_equal true, course['confirmed']
    assert_equal '人101', course['read_as']
  end

  test '画面を開いたあとに変わった科目は、古い画面の値で上書きせず、断る' do
    draft = course_draft
    show(draft)
    rev = css_select('#course-course_人101 button[formaction*="confirmed"]').first['formaction'][/rev=(\h+)/, 1]
    update_course(draft, key: 'course_人101', credits: '3')

    update_course(draft, key: 'course_人101', confirmed: '1', rev: rev)

    assert_redirected_to curriculum_path(draft)
    follow_redirect!
    assert_select '.border-rose-200, [role=alert]', text: /画面を開いたあとに変わっています/
    assert_equal 3, course_in(draft, '人101')['credits']
  end

  test '読み直しなどで無くなった科目への保存は、何も変えずに画面を開き直させる' do
    draft = course_draft

    update_course(draft, key: 'course_vanished', confirmed: '1')

    assert_redirected_to curriculum_path(draft)
    assert_equal fixture_courses.size, draft.reload.document['courses'].size
  end

  test '番号だけで科目を指すとき、同じ番号が2つあれば、どちらも変えない' do
    document = requirements_document
    document['courses'] << fixture_course('人101', '別の行', 'humanities').merge('key' => 'dup_key')
    draft = course_draft(document: document)

    update_course(draft, number: '人101', confirmed: true)

    assert_redirected_to curriculum_path(draft)
    assert(draft.reload.document['courses'].none? { |course| course['confirmed'] })
  end

  test '科目を消せる。AIが読んだ科目は読み直しで戻らないよう記録され、画面からも消える' do
    draft = course_draft

    update_course(draft, key: 'course_人103', _destroy: '1')

    assert_nil course_in(draft, '人103')
    tombstone = draft.document['removed_by_human'].first
    assert_equal({ 'kind' => 'course', 'id' => 'course_人103', 'page' => 3, 'identity' => '人103' },
                 tombstone.except('fingerprint'))
    assert_match(/\A\h{16}\z/, tombstone['fingerprint'], '同じ番号の行のどれかを見分ける、読みの中身の指紋')
    show(draft)
    assert_select '#course-course_人103', count: 0
    assert_select '#course-review h4', text: /人文系 ・ 2科目/
  end

  test '科目の削除で、開いたままの要件表の画面は古いと断られない' do
    draft = course_draft
    show(draft)
    revision = css_select('#requirements_form input[name=revision]').first['value']

    update_course(draft, key: 'course_人103', _destroy: '1')

    assert_equal revision, revision_of(draft)
  end

  test '承認の印: 確認した科目は、注記が付けた印が外れる' do
    document = requirements_document
    document['courses'][0].merge!('requires_approval' => true, 'approval_by_note' => true)
    draft = course_draft(document: document)

    update_course(draft, number: '人101', confirmed: true)

    assert_nil course_in(draft, '人101')['approval_by_note']
    assert course_in(draft, '人101')['requires_approval']
  end

  test '承認の印: 承認の要否を人が直した科目も、印が外れる' do
    document = requirements_document
    document['courses'][0].merge!('requires_approval' => true, 'approval_by_note' => true)
    draft = course_draft(document: document)

    update_course(draft, key: 'course_人101', requires_approval: '0')

    assert_not course_in(draft, '人101')['requires_approval']
    assert_nil course_in(draft, '人101')['approval_by_note']
  end

  test '承認の印: 確認を外しても、いちど外した印は戻らない' do
    document = requirements_document
    document['courses'][0].merge!('requires_approval' => true, 'approval_by_note' => true)
    draft = course_draft(document: document)

    update_course(draft, number: '人101', confirmed: true)
    assert_nil course_in(draft, '人101')['approval_by_note']
    update_course(draft, number: '人101', confirmed: false)

    assert_equal false, course_in(draft, '人101')['confirmed']
    assert_nil course_in(draft, '人101')['approval_by_note']
    assert course_in(draft, '人101')['requires_approval'], '承認の関門は残る(安全側)'
  end

  test '確認していない科目の印は、ほかの科目を確認しても残る' do
    document = requirements_document
    document['courses'][1].merge!('requires_approval' => true, 'approval_by_note' => true)
    draft = course_draft(document: document)

    update_course(draft, number: '人101', confirmed: true)

    assert course_in(draft, '人102')['approval_by_note']
  end

  test '承認の要否は、どちらの状態でも行に書く。選べる/選べないのボタンは、押したときに切り替わると読み上げに言う' do
    document = requirements_document
    document['courses'][0]['requires_approval'] = true
    show(course_draft(document: document))

    assert_select '#course-course_人101 .cr-warn', text: '承認が必要'
    assert_select '#course-course_人102', text: /承認不要/
    assert_select '#course-course_人102 td button[aria-pressed=true]', text: '選べる'
    assert_select '#course-course_情01 td button.cr-btn-bad[aria-pressed=false]', text: '選べない'
  end

  test '人が直した値を持つ科目の確認を外すボタンは、押す前に確かめる。直していない科目は確かめない' do
    draft = course_draft
    update_course(draft, key: 'course_人101', credits: '3')
    update_course(draft, key: 'course_人102', confirmed: '1')

    show(draft)

    assert_select '#course-course_人101 button[aria-pressed=true][data-turbo-confirm*="直した値は AI の読みに戻ります"]'
    assert_select '#course-course_人102 button[aria-pressed=true]:not([data-turbo-confirm])'
  end

  test '確認したあとに承認の注記が付いた科目は、もう一度見る印つきで最初に見る科目に出て、確認し直すと外れる' do
    document = requirements_document
    document['courses'][0].merge!('confirmed' => true, 'requires_approval' => true, 'review_again' => true)
    draft = course_draft(document: document)

    show(draft)
    assert_equal '人101', rows.first.at_css('td.tabular-nums').text.squish.split.first
    assert_select '#course-first-look h4', text: /最初に見る科目 ・ 1科目/
    assert_select '#course-course_人101', text: /承認の注記が付きました。もう一度確認してください/
    assert_select '#course-course_人101 button[aria-pressed=false]', text: 'もう一度確認した'
    assert_select '#courses_summary', text: /確認済み 0件/

    patch css_select('#course-course_人101 button[aria-pressed=false]').first['formaction'], env: ENV_LOCAL

    assert_nil course_in(draft, '人101')['review_again']
    assert confirmed?(draft, '人101')
    show(draft)
    assert_select '#course-first-look', count: 0
  end

  test '画面のボタンは、そのまま科目1つを保存する(押したときと同じ要求を送る)' do
    draft = course_draft
    show(draft)
    button = css_select('#course-course_情01 button.cr-btn-bad').first

    patch button['formaction'], env: ENV_LOCAL

    assert course_in(draft, '情01')['selectable'], '選べないを押すと、選べるになる'
    assert confirmed?(draft, '情01'), '値を直した科目は、確認済みになる'
    show(draft)
    assert_select '#course-course_情01 button.cr-btn-bad', count: 0
    assert_select '#course-course_情01 button[aria-pressed=true]', text: '✓ 確認した'
  end

  test '番号帯から推定した区分にするボタンで、区分を直せる' do
    draft = course_draft(document: mismatch_document)
    show(draft)
    button = css_select('#course-first-look + tbody button').find { |node| node.text == '推定の区分にする' }

    patch button['formaction'], env: ENV_LOCAL

    assert_equal 'required_core', course_in(draft, '知能105')['category']
    assert confirmed?(draft, '知能105')
  end

  # ---- Turbo の画面: 行だけを差し替える ----

  test 'Turbo: 保存すると、その科目の行と件数だけを差し替える' do
    draft = course_draft

    update_course(draft, headers: STREAM, key: 'course_人101', credits: '4')

    assert_response :success
    assert_equal 'text/vnd.turbo-stream.html', response.media_type
    streams = streams_of(response)
    assert_equal %w[replace replace replace update], streams.pluck('action')
    assert_equal %w[course-course_人101 courses_summary courses_errors courses_notice], streams.pluck('target')
    assert_includes streams.first.text.squish, '✓ 確認した'
    assert_includes streams.last.text, '人101「哲学」を直しました(単位)'
    assert_includes streams[1].text.squish, '確認済み 1件'
  end

  test 'Turbo: 保存できないときは422で、その科目の行を打った値つきの編集欄ごと差し替え、上にも問題を出す' do
    draft = course_draft

    update_course(draft, headers: STREAM, key: 'course_人101', credits: '4単位')

    assert_response :unprocessable_content
    streams = streams_of(response)
    assert_equal 'course-course_人101', streams.first['target']
    row = Nokogiri::HTML5.fragment("<table>#{streams.first.at_css('template').inner_html}</table>")
    assert_equal '4単位', row.at_css('#course-edit-course_人101 input[name=credits]')['value']
    assert_includes streams[2].text, '4単位'
  end

  test 'Turbo: 消した科目は、行ごと外す' do
    draft = course_draft

    update_course(draft, headers: STREAM, key: 'course_人103', _destroy: '1')

    assert_equal %w[remove], streams_of(response).pluck('action').first(1)
    assert_equal 'course-course_人103', streams_of(response).first['target']
  end

  test 'Turbo: 足したときと、画面が古いときは、画面を開き直させる' do
    draft = course_draft

    update_course(draft, headers: STREAM, number: '知能999', name: '追加', credits: '2', category: 'fusion',
                         added_by_hand: '1')
    assert_redirected_to curriculum_path(draft, anchor: 'course-course_知能999')

    update_course(draft, headers: STREAM, key: 'course_vanished', confirmed: '1')
    assert_redirected_to curriculum_path(draft)
  end

  # ---- 直す欄 ----

  test '「直す」を押すと、その科目の行のあとへ編集欄だけが入る' do
    draft = course_draft

    get edit_course_curriculum_path(draft, key: 'course_人101'), headers: STREAM, env: ENV_LOCAL

    assert_response :success
    streams = streams_of(response)
    assert_equal %w[remove append], streams.pluck('action')
    assert_equal 'course-course_人101', streams.last['target']
    html = Nokogiri::HTML5.fragment("<table>#{streams.last.at_css('template').inner_html}</table>")
    assert_equal 'course-edit-course_人101', html.at_css('tr')['id']
    assert_equal '哲学', html.at_css('input[name=name]')['value']
    assert_equal 'humanities', html.at_css('select[name=category] option[selected]')['value']
    assert_equal 'course_人101', html.at_css('input[name=key]')['value']
    assert html.at_css('input[name=rev]')['value'].present?
    assert_equal %w[credits language name number review_reason roles].sort,
                 html.css('input[type=text]').pluck('name').sort
  end

  test '「やめる」は、編集欄を閉じるだけ' do
    draft = course_draft

    get edit_course_curriculum_path(draft, key: 'course_人101', cancel: 1), headers: STREAM, env: ENV_LOCAL

    assert_equal %w[remove], streams_of(response).pluck('action')
  end

  test '編集欄は、Turbo を使わずに開いても、その科目だけの画面になる。無い科目は404' do
    draft = course_draft

    get edit_course_curriculum_path(draft, key: 'course_人101'), env: ENV_LOCAL
    assert_response :success
    assert_select 'h2', text: /人101 哲学 を直す/
    assert_select 'form[action=?]', update_courses_curriculum_path(draft)

    get edit_course_curriculum_path(draft, key: 'nothing'), env: ENV_LOCAL
    assert_response :not_found
  end

  # ---- 重さ ----

  # COURSES_REVIEW_STATS=1 で、実際の重さを出す(画面の重さは、作った人が数字で知っておくもの)。
  def report_weight(section, fields, elapsed)
    puts "\n[科目表の画面] #{section.bytesize / 1024}KB #{fields}欄 #{rows.size}科目 #{(elapsed * 1000).round}ms " \
         "(全体 #{response.body.bytesize / 1024}KB)"
  end

  test '484科目でも、画面の重さと欄の数を抑える' do
    real = JSON.parse(Rails.root.join('config/curricula/intelligent_informatics/2024.json').read)
    draft = course_draft(document: real)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    show(draft)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    section = response.body[response.body.index('id="course-review"')..]
    fields = Nokogiri::HTML5.fragment(section).css('input, select, textarea').size
    report_weight(section, fields, elapsed) if ENV['COURSES_REVIEW_STATS']
    assert_equal 484, rows.size
    assert_operator section.bytesize, :<, 700_000, '1科目あたり約1.4KBを超えて、画面が重くなった'
    assert_operator response.body.bytesize, :<, 1_000_000, '画面全体(要件表の半分を含む)が1MBを超えた'
    assert_operator fields, :<=, 30, '科目ごとに欄を置いた(484行ぶんの欄は、フォームの送信とブラウザの描画を重くする)'
  end
end

