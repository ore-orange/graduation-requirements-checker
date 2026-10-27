# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require 'tempfile'

class CourseRegistrationsTest < ActionDispatch::IntegrationTest
  ENV_LOCAL = { 'REMOTE_ADDR' => '127.0.0.1' }.freeze

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
  end

  teardown do
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
  end

  # gsの出力と同じ形の座標付きXML。1科目ぶん。
  def timetable_xml(periods: '2・3')
    cells = { 64 => '610000071', 107 => '工共100', 167 => '工学基礎演習', 250 => '2', 310 => '必', 477 => '1',
              505 => '金', 523 => periods, 686 => '1Q' }
    spans = cells.map { |left, text| span(text, left, 153) } + [span('(許可コード)', 723, 124)]
    "<page>\n#{spans.join("\n")}\n</page>\n"
  end

  def span(text, left, top)
    chars = text.chars.map { |char| %(<char bbox="#{left} #{top} #{left + 1} #{top}" c="#{CGI.escapeHTML(char)}"/>) }
    %(<span bbox="#{left} #{top} #{left + (text.size * 5)} #{top}" font="F" size="10">#{chars.join}</span>)
  end

  def upload_pdf(xml: timetable_xml, content: "%PDF-1.4\nbody", **params)
    file = Tempfile.new(['timetable', '.pdf'])
    file.write(content)
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, 'application/pdf')
    TimetableImport::PdfParser.stub(:extract_xml, xml) do
      # 画像化(gs)はテストでは動かさない。ページ画像を使うテストは自分で置く。
      TimetableImport::PageImages.stub(:render, ->(_pdf, _dir) { 0 }) do
        post timetable_uploads_path, params: upload_params(pdf: upload, **params), env: ENV_LOCAL
      end
    end
  ensure
    file&.close!
  end

  # 取り込みのモーダルが送る内容。引数で一部だけ差し替えられる。
  def upload_params(**overrides)
    { semester: '前期', year: 2026, department_id: sample_department.id }.merge(overrides)
  end

  ROW_LABELS = { lecture_code: '講義コード', name: '科目名', course_number: '科目番号' }.freeze

  # Importerに渡す1行。保存済みの講義を用意するのに使う。
  def offering_row(**overrides)
    { '学期' => '前期', '講義コード' => '610000071', '科目番号' => '工共100', '科目名' => '工学基礎演習',
      '単位' => '2', '必修選択' => '必修', '受講年次' => '1', '曜日' => '金', '時限' => '2・3',
      '開講区分' => '1Q', '要確認' => '' }
      .merge(overrides.transform_keys { |key| ROW_LABELS.fetch(key) })
  end

  # 画面を経由せずに講義を保存する。年度・学科は取り込み全体で1つ。
  def import_rows(rows, year: 2026)
    TimetableImport::Importer.new(rows, year: year, department_id: sample_department.id).call(apply: true)
  end

  # 確認画面の「更新」と同じ形で送る。changesは { 行 => { 項目 => 値 } }、confirmedはチェックを入れる行。
  def update_rows(upload, changes: {}, confirmed: [], operation: 'update', **extra)
    rows = changes.to_h { |row, values| [row.id, row.slice(*TimetableUploadRow::EDITABLE).merge(values)] }
    params = { rows: rows, confirmed: confirmed.to_h { |row| [row.id, '1'] }, operation: operation }
    patch update_rows_timetable_upload_path(upload), params: params.merge(extra), env: ENV_LOCAL
  end

  def create_upload
    upload_pdf
    TimetableUpload.order(:id).last
  end

  def create_large_upload(count = 35)
    upload = TimetableUpload.create!(semester: '前期', year: 2026, department: sample_department,
                                     source_filename: 'big.pdf')
    count.times do |index|
      upload.rows.create!(position: index, lecture_code: format('%09d', index), course_number: "工共#{100 + index}",
                          name: "科目#{index + 1}", credits: '2', requirement_type: '必修', grade_text: '1',
                          weekday: '月', period_text: '1', term_type: '半年')
    end
    upload
  end

  def registered_course
    Course.create!(course_number: '工共100', name: '工学基礎演習', credits: 2)
  end

  test 'tab is shown in the navigation and lists registered offerings' do
    import_rows([{ '学期' => '前期', '講義コード' => '1', '科目番号' => '工共100', '科目名' => '工学基礎演習',
                   '単位' => '2', '必修選択' => '必修', '受講年次' => '1', '曜日' => '金', '時限' => '2・3',
                   '開講区分' => '1Q', '要確認' => '' }])

    get course_registrations_path, env: ENV_LOCAL

    assert_response :success
    assert_select 'nav a[aria-current=page]', text: '講義登録'
    assert_select 'td', text: '工学基礎演習'
    assert_select 'button', text: '講義を追加'
    assert_select 'dialog form input[type=file][accept="application/pdf"]'
    assert_select 'dialog', text: /必ず、読み取った内容をPDFと見比べてください/
    assert_select 'dialog', text: /知能情報コースの授業時間配当表にのみ対応/
  end

  test 'upload parses the pdf into unconfirmed rows without touching courses' do
    assert_no_difference ['Course.count', 'CourseOffering.count'] do
      assert_difference 'TimetableUpload.count', 1 do
        upload_pdf
      end
    end

    upload = TimetableUpload.last
    assert_redirected_to timetable_upload_path(upload)
    assert_equal '前期', upload.semester
    row = upload.rows.first
    assert_equal ['工学基礎演習', '必修', '2・3', false], [row.name, row.requirement_type, row.period_text, row.confirmed]
  end

  test 'page images are served for the pages that exist only' do
    upload = create_upload
    FileUtils.mkdir_p(upload.images_dir)
    File.binwrite(upload.images_dir.join('p1.png'), 'png')

    get page_image_timetable_upload_path(upload, 1), env: ENV_LOCAL
    assert_response :success
    assert_equal 'image/png', response.media_type

    get page_image_timetable_upload_path(upload, 2), env: ENV_LOCAL
    assert_response :not_found

    get page_image_timetable_upload_path(upload, 'one'), env: ENV_LOCAL
    assert_response :not_found
  end

  test 'the pdf pane shows every page, and is left out when there are no images' do
    upload = create_upload
    FileUtils.mkdir_p(upload.images_dir)
    [1, 2].each { |page| File.binwrite(upload.images_dir.join("p#{page}.png"), 'png') }

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select 'thead[data-controller=pdf-pane] tr#pdf-pane-row'
    assert_select "img[src='#{page_image_timetable_upload_path(upload, 1)}']"
    assert_select "img[src='#{page_image_timetable_upload_path(upload, 2)}']"
    assert_select 'button', text: '幅に合わせる'
    assert_select 'button[data-page="2"]', text: '2'
    # 更新のたびにペインが作り直されると、倍率や高さ、隠した状態が戻ってしまう
    assert_select 'tr#pdf-pane-row[data-turbo-permanent]'
    assert_select 'tr#pdf-pane-hidden-row[data-turbo-permanent]'

    without_images = create_upload
    get timetable_upload_path(without_images), env: ENV_LOCAL
    assert_response :success
    assert_select 'tr#pdf-pane-row', 0
  end

  test 'upload rejects files that are not pdfs and unknown semesters' do
    assert_no_difference 'TimetableUpload.count' do
      upload_pdf(content: 'not a pdf')
      assert_match 'PDFファイル', flash[:alert]
      upload_pdf(semester: '通年')
      assert_match '前期か後期', flash[:alert]
    end
  end

  test '絞り込むと当たった講義だけが出る' do
    import_rows([offering_row(lecture_code: 'k001', name: '情報処理概論', course_number: '工共100'),
                 offering_row(lecture_code: 'k002', name: '線形代数', course_number: '工共200')])

    get course_registrations_path(name: '情報'), env: ENV_LOCAL

    assert_response :success
    assert_select 'td', text: '情報処理概論'
    assert_select 'td', text: '線形代数', count: 0
  end

  test '絞り込みの条件はページ送りのリンクに残る' do
    import_rows(Array.new(31) do |index|
      offering_row(lecture_code: format('%09d', index), name: "情報処理概論#{index}", course_number: "工共#{index}")
    end)

    get course_registrations_path(name: '情報'), env: ENV_LOCAL

    assert_select 'nav[aria-label=ページ送り] a[href*="name="]'
  end

  test '条件に当たる講義が無いときは、まだ1件も無いときと違う案内を出す' do
    import_rows([offering_row(lecture_code: 'k001', name: '線形代数', course_number: '工共100')])

    get course_registrations_path(name: '当たらない'), env: ENV_LOCAL
    assert_select 'p', text: /条件に当たる講義がありません/

    get course_registrations_path, env: ENV_LOCAL
    assert_select 'p', text: /まだ保存された講義はありません/, count: 0
  end

  test 'まだ1件も保存されていないときは、その案内を出す' do
    get course_registrations_path, env: ENV_LOCAL

    assert_select 'p', text: /まだ保存された講義はありません/
  end

  test '保存済みの講義には年度と学部・学科が出る' do
    import_rows([offering_row(lecture_code: 'k001', name: '情報処理概論', course_number: '工共100')])

    get course_registrations_path, env: ENV_LOCAL

    assert_select 'td', text: '2026'
    assert_select 'td', text: "#{sample_department.faculty.name} #{sample_department.name}"
  end

  test '年度・学部・学科で絞り込むプルダウンが検索バーにある' do
    import_rows([offering_row(lecture_code: 'k001', name: '情報処理概論', course_number: '工共100')])

    get course_registrations_path, env: ENV_LOCAL

    assert_select 'form[method=get] select[name=year]'
    assert_select 'form[method=get] select[name=faculty_id]'
    assert_select 'form[method=get] select[name=department_id]'
    assert_select 'form[method=get] input[name=course_number]'
    assert_select 'form[method=get] input[name=lecture_code]'
    assert_select 'form[method=get] input[name=name]'
  end

  test '年度・学部・学科を選んで取り込むと、取り込みに残る' do
    upload_pdf

    upload = TimetableUpload.sole
    assert_equal 2026, upload.year
    assert_equal sample_department.id, upload.department_id
  end

  test '年度が数字でないときは取り込まない' do
    assert_no_difference 'TimetableUpload.count' do
      upload_pdf(year: 'あ')
    end
    assert_redirected_to course_registrations_path
    assert_match '年度', flash[:alert]
  end

  test '学科が選ばれていない、または存在しないときは取り込まない' do
    assert_no_difference 'TimetableUpload.count' do
      upload_pdf(department_id: '')
      assert_match '学科', flash[:alert]
      upload_pdf(department_id: '999999')
      assert_match '学科', flash[:alert]
    end
  end

  test 'upload reports a pdf without any course rows' do
    assert_no_difference 'TimetableUpload.count' do
      upload_pdf(xml: "<page>\n</page>")
    end
    assert_match '科目の行を見つけられません', flash[:alert]
  end

  test 'fixed-value fields are selects, the period is free input, and the page has one save button in the footer' do
    upload = create_upload
    row = upload.rows.first

    get timetable_upload_path(upload), env: ENV_LOCAL

    %w[requirement_type grade_text weekday term_type].each do |field|
      assert_select "select[name='rows[#{row.id}][#{field}]']"
    end
    assert_select "[data-controller=combobox] input[name='rows[#{row.id}][period_text]']"
    assert_select '[data-controller=combobox] li[data-value="3・4・5"]'
    assert_select "input[type=number][name='rows[#{row.id}][credits]']"
    assert_select 'button', text: '保存する', count: 1
    assert_select 'input[type=submit][value=更新]', 0
    assert_select 'thead.sticky'
    assert_select 'form#rows-form'
    assert_select 'p', text: /必ず、PDFと見比べて内容を確認してください/
  end

  test 'cannot commit until every row is confirmed' do
    upload = create_upload

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select 'button[disabled]', text: '保存する'

    assert_no_difference 'CourseOffering.count' do
      post commit_timetable_upload_path(upload), env: ENV_LOCAL
    end
    assert_match '未確認', flash[:alert]
    assert TimetableUpload.exists?(upload.id)
  end

  test 'editing and confirming rows then committing saves and clears the upload' do
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'weekday' => '月' } }, confirmed: [row])
    assert_predicate row.reload, :confirmed
    assert_equal '月', row.weekday
    follow_redirect!

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select 'button:not([disabled])', text: '保存する'

    assert_difference ['Course.count', 'CourseOffering.count'], 1 do
      post commit_timetable_upload_path(upload), env: ENV_LOCAL
    end
    assert_redirected_to course_registrations_path
    assert_equal '月', CourseOffering.find_by!(lecture_code: '610000071').weekday
    assert_not TimetableUpload.exists?(upload.id)
  end

  test 'edits are saved even when the row is not checked' do
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'name' => '工学基礎演習A' } })

    assert_equal '工学基礎演習A', row.reload.name
    assert_not row.confirmed
  end

  test 'a row with invalid values is not confirmed and is shown in red with the reason' do
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'period_text' => '4(・5)' } }, confirmed: [row])

    assert_not row.reload.confirmed
    assert_equal '4(・5)', row.period_text
    follow_redirect!
    assert_select '[role=alert][data-controller=toast]', text: /確認済みにできない行が1行/
    assert_select '[role=alert][data-toast-auto-dismiss-value]', 0
    assert_select "tbody#row-#{row.id}.bg-red-50"
    assert_select "tbody#row-#{row.id} td", text: /時限は「2・3」のように/
  end

  test 'the period can be set freely, including a run of three that is not among the suggestions' do
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'period_text' => '３・４・５' } }, confirmed: [row])

    assert_equal '3・4・5', row.reload.period_text
    assert_predicate row, :confirmed

    post commit_timetable_upload_path(upload), env: ENV_LOCAL
    assert_equal [3, 4, 5], CourseOffering.find_by!(lecture_code: '610000071').periods
  end

  test 'updating says nothing: the row colours and the counter are the feedback' do
    upload = create_upload
    row = upload.rows.first

    get timetable_upload_path(upload), env: ENV_LOCAL # 取り込み直後の知らせを流しておく
    update_rows(upload, changes: { row => { 'weekday' => '月' } }, confirmed: [row])
    follow_redirect!

    assert_select '[role=status]', 0
    assert_equal '月', row.reload.weekday
    assert_predicate row, :confirmed
  end

  test 'success messages dismiss themselves and sit at the right edge' do
    upload_pdf
    follow_redirect!

    assert_select 'div.right-4 [role=status][data-toast-auto-dismiss-value="5000"]', text: /PDFを読み取りました/
  end

  test 'confirm all covers every row but skips rows flagged for review' do
    upload = create_large_upload
    flagged = upload.rows.find_by!(position: 34)
    flagged.update!(review_reason: '時限が不明')

    update_rows(upload, operation: 'confirm_all')

    assert_redirected_to timetable_upload_path(upload)
    assert_equal 34, upload.rows.where(confirmed: true).count
    assert_not flagged.reload.confirmed
  end

  test 'the confirmation screen lists every row at once, without pagination' do
    upload = create_large_upload

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select 'tbody[id^=row-]', 35
    assert_select 'input[value=科目35]', 1
    assert_select 'nav[aria-label=ページ送り]', 0
  end

  test 'the add target survives an update, so rows can be added one after another' do
    upload = create_upload

    get timetable_upload_path(upload), env: ENV_LOCAL

    assert_select 'input[name=after_row_id][data-turbo-permanent]'
  end

  test 'checking a row submits right away, so there is no separate update button' do
    upload = create_upload
    row = upload.rows.first

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select "input[type=checkbox][name='confirmed[#{row.id}]'][data-action='change->checks#toggle']"
    assert_select 'button', text: '問題のない行をまとめて確認済みにする'
    assert_select 'button[form=rows-form][value=update]', 0
  end

  test 'adding a row puts an empty row right after the chosen one and keeps the edits' do
    upload = create_large_upload(3)
    first = upload.rows.first

    assert_difference -> { upload.rows.reload.size }, 1 do
      update_rows(upload, changes: { first => { 'name' => '直した名前' } }, operation: 'add_row', after_row_id: first.id)
    end

    assert_equal '直した名前', first.reload.name
    added = upload.rows.reload[1]
    assert_predicate added, :added_by_hand
    assert_equal '', added.name.to_s
    assert_not added.confirmed
    assert_equal [0, 1, 2, 3], upload.rows.map(&:position)
  end

  test 'adding a row without a target, or with a row from another upload, appends it to the end' do
    upload = create_large_upload(3)
    other = create_large_upload(1).rows.first

    update_rows(upload, operation: 'add_row')
    assert_predicate upload.rows.reload.last, :added_by_hand

    update_rows(upload, operation: 'add_row', after_row_id: other.id)
    assert_equal 5, upload.rows.reload.size
    assert_predicate upload.rows.last, :added_by_hand
    assert_equal [0, 1, 2, 3, 4], upload.rows.map(&:position)
  end

  test 'a hand-added row is marked, can be deleted, and keeps the edits in the same submit' do
    upload = create_large_upload(2)
    first = upload.rows.first
    update_rows(upload, operation: 'add_row', after_row_id: first.id)
    added = upload.rows.reload[1]

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select "tbody#row-#{added.id}", text: /手で追加した行/
    assert_select "button[name=destroy_row_id][value='#{added.id}'][data-turbo-confirm]"

    assert_difference -> { upload.rows.reload.size }, -1 do
      update_rows(upload, changes: { first => { 'name' => '直した名前' } }, destroy_row_id: added.id)
    end
    assert_equal '直した名前', first.reload.name
  end

  test 'adding without a target goes to the very end, even after a row was deleted' do
    upload = create_large_upload(3)
    update_rows(upload, operation: 'add_row', after_row_id: upload.rows.first.id)
    update_rows(upload, destroy_row_id: upload.rows.reload[1].id)

    update_rows(upload, operation: 'add_row')

    assert_predicate upload.rows.reload.last, :added_by_hand
    assert_equal '科目3', upload.rows[-2].name
  end

  test 'a hand-added row can be filled in, confirmed and committed with the rest' do
    upload = create_upload
    parsed = upload.rows.first
    update_rows(upload, operation: 'add_row', after_row_id: parsed.id)
    added = upload.rows.reload.last

    # 空のままでは確認済みにできない
    update_rows(upload, changes: { added => {} }, confirmed: [added])
    assert_not added.reload.confirmed
    follow_redirect!
    assert_select "tbody#row-#{added.id} td", text: /科目名が空です/

    filled = { 'lecture_code' => '610000099', 'course_number' => '工共199', 'name' => '読み落とした科目',
               'credits' => '2', 'requirement_type' => '選択', 'grade_text' => '2', 'weekday' => '木',
               'period_text' => '3・4・5', 'term_type' => '半年' }
    update_rows(upload, changes: { added => filled, parsed => {} }, confirmed: [added, parsed])
    assert_predicate added.reload, :confirmed

    assert_difference ['Course.count', 'CourseOffering.count'], 2 do
      post commit_timetable_upload_path(upload), env: ENV_LOCAL
    end
    offering = CourseOffering.find_by!(lecture_code: '610000099')
    assert_equal [[3, 4, 5], '木', '読み落とした科目'], [offering.periods, offering.weekday, offering.course.name]
  end

  test 'a row id from another upload is not deleted' do
    upload = create_large_upload(2)
    other = create_large_upload(1).rows.first

    assert_no_difference -> { TimetableUploadRow.count } do
      update_rows(upload, destroy_row_id: other.id)
    end
    assert TimetableUploadRow.exists?(other.id)
  end

  test 'only rows sent from the screen are touched' do
    upload = create_large_upload
    sent = upload.rows.find_by!(position: 0)
    other = upload.rows.find_by!(position: 33)

    update_rows(upload, changes: { sent => { 'name' => '変更後' } }, confirmed: [sent])

    assert_equal '変更後', sent.reload.name
    assert_equal '科目34', other.reload.name
    assert_not other.confirmed
  end

  test 'saved offerings list is paginated at the bottom only' do
    rows = Array.new(35) do |index|
      { '学期' => '前期', '講義コード' => format('%09d', index), '科目番号' => "工共#{index}", '科目名' => "科目#{index}",
        '単位' => '2', '必修選択' => '必修', '受講年次' => '1', '曜日' => '月', '時限' => '1', '開講区分' => '半年',
        '要確認' => '' }
    end
    import_rows(rows)

    get course_registrations_path, env: ENV_LOCAL
    assert_select 'nav[aria-label=ページ送り]', 1
    assert_select 'tbody tr', 30
    get course_registrations_path(page: 2), env: ENV_LOCAL
    assert_select 'tbody tr', 5
  end

  # 同じ名前・番号の講義が1件で単位も同じなら、既存の講義が既定で選ばれる
  test 'a single matching course with the same credits is selected by default and shown compactly' do
    course = registered_course
    upload = create_upload
    row = upload.rows.first

    assert_equal course, row.course
    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select "select[name='rows[#{row.id}][course_choice]'] option[selected]", text: '既存の講義として扱う'
    assert_select "select[name='rows[#{row.id}][course_choice]'] option", text: '別の講義として登録'
    assert_select "select[name='rows[#{row.id}][course_choice]'] option", text: '選んでください', count: 0
    assert_select "tbody#row-#{row.id} .text-red-700", 0

    update_rows(upload, changes: { row => {} }, confirmed: [row])
    assert_predicate row.reload, :confirmed

    assert_no_difference 'Course.count' do
      assert_difference 'CourseOffering.count', 1 do
        post commit_timetable_upload_path(upload), env: ENV_LOCAL
      end
    end
    assert_equal course, CourseOffering.find_by!(lecture_code: '610000071').course
  end

  test 'rows without an overlapping course show no choice at all' do
    upload = create_upload
    row = upload.rows.first

    get timetable_upload_path(upload), env: ENV_LOCAL

    assert_nil row.course
    assert_select "select[name='rows[#{row.id}][course_choice]']", 0
    assert_select 'p', text: /被っています/, count: 0
    assert_select 'span', text: /被っています/, count: 0
  end

  test 'several matching courses leave the choice open and block confirming until chosen' do
    first = registered_course
    Course.create!(course_number: '工共100', name: '工学基礎演習', credits: 2)
    upload = create_upload
    row = upload.rows.first

    assert_nil row.course
    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select "select[name='rows[#{row.id}][course_choice]'] option", text: '選んでください'
    assert_select "tbody#row-#{row.id} .text-red-700", text: /選んでください/

    update_rows(upload, changes: { row => {} }, confirmed: [row])
    assert_not row.reload.confirmed
    follow_redirect!
    assert_select "tbody#row-#{row.id} td", text: /同じ講義として扱うか、別の講義として登録するか/

    update_rows(upload, changes: { row => { 'course_choice' => first.id.to_s } }, confirmed: [row])
    assert_predicate row.reload, :confirmed
    assert_equal first, row.course
  end

  test 'a matching course with different credits is not selected by default' do
    Course.create!(course_number: '工共100', name: '工学基礎演習', credits: 1)
    upload = create_upload
    row = upload.rows.first

    assert_nil row.course
    assert_not row.register_as_new
    update_rows(upload, changes: { row => {} }, confirmed: [row])
    assert_not row.reload.confirmed
  end

  test 'choosing the existing course and then changing the credits cannot be confirmed' do
    registered_course
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'credits' => '4' } }, confirmed: [row])

    assert_not row.reload.confirmed
    follow_redirect!
    assert_select "tbody#row-#{row.id} td", text: /選んだ既存の講義の単位\(2\)と違います/
  end

  test 'choosing a new course registers a separate course even with the same name and number' do
    registered_course
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'course_choice' => 'new' } }, confirmed: [row])
    assert_predicate row.reload, :confirmed
    assert_nil row.course
    assert_predicate row, :register_as_new

    assert_difference 'Course.count', 1 do
      post commit_timetable_upload_path(upload), env: ENV_LOCAL
    end
    assert_equal 2, Course.where(course_number: '工共100', name: '工学基礎演習').count
  end

  test 'editing the name or number drops the old choice and picks the default again' do
    course = registered_course
    other = Course.create!(course_number: '工共200', name: '別の講義', credits: 2)
    upload = create_upload
    row = upload.rows.first
    assert_equal course, row.course

    update_rows(upload, changes: { row => { 'course_number' => '工共200', 'name' => '別の講義' } })
    assert_equal other, row.reload.course

    update_rows(upload, changes: { row => { 'course_number' => '工共999' } })
    assert_nil row.reload.course
    assert_not row.register_as_new
  end

  test 'a choice that is not among the candidates is ignored and the default is kept' do
    course = registered_course
    other = Course.create!(course_number: '別', name: '別の講義', credits: 1)
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'course_choice' => other.id.to_s } })

    assert_equal course, row.reload.course
  end

  test 'a row that cannot be confirmed is shown in red with the reason' do
    upload = create_large_upload
    broken = upload.rows.find_by!(position: 2)
    broken.update!(period_text: '4(・5)')

    update_rows(upload, changes: { broken => {} }, confirmed: [broken])

    assert_not broken.reload.confirmed
    assert_redirected_to timetable_upload_path(upload)
    follow_redirect!
    assert_select '[role=alert]', text: /確認済みにできない行が1行あります/
    assert_select "tbody#row-#{broken.id}[data-error-row].bg-red-50"
  end

  test 'rows that were not sent keep their state' do
    upload = create_large_upload
    untouched = upload.rows.find_by!(position: 3)
    sent = upload.rows.find_by!(position: 0)

    update_rows(upload, changes: { sent => { 'name' => '変更後' } })

    assert_not untouched.reload.confirmed
  end

  test 'the screen offers select-all and the first error row to scroll to' do
    upload = create_large_upload
    row = upload.rows.first

    get timetable_upload_path(upload), env: ENV_LOCAL

    assert_select 'form#rows-form[data-controller~=checks][data-controller~=scroll-to-error]'
    assert_select 'th input[type=checkbox][data-checks-target=all]', 1
    assert_select "input[type=checkbox][name='confirmed[#{row.id}]'][data-checks-target=box][data-row-id='#{row.id}']"
    assert_select 'tbody[data-error-row]', 0
  end

  test 'the disabled save button explains why with text and a tooltip' do
    upload = create_large_upload

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select '#save-reason', text: /あと35行を確認済みにすると保存できます/
    assert_select '[role=tooltip]', text: /あと35行を確認済みにすると保存できます/
    assert_select 'button[disabled][aria-describedby=save-reason]', text: '保存する'

    upload.rows.each { |row| row.update!(confirmed: true) }
    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select '[role=tooltip]', 0
    assert_select 'button:not([disabled])', text: '保存する'
  end

  test 'the confirmation screen uses the wide layout and the list keeps the standard width' do
    upload = create_large_upload

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select 'main.max-w-\\[110rem\\]'
    assert_select 'main.max-w-7xl', 0

    get course_registrations_path, env: ENV_LOCAL
    assert_select 'main.max-w-7xl'
  end

  test 'opening a missing upload goes back to the list with a message' do
    get timetable_upload_path(0), env: ENV_LOCAL

    assert_redirected_to course_registrations_path
    assert_match '見つかりません', flash[:alert]
  end

  test 'discarding an upload removes it without touching courses' do
    upload = create_upload

    assert_no_difference ['Course.count', 'CourseOffering.count'] do
      assert_difference 'TimetableUpload.count', -1 do
        delete timetable_upload_path(upload), env: ENV_LOCAL
      end
    end
  end

  test 'all screens are hidden outside local access' do
    upload = create_upload
    remote = { 'REMOTE_ADDR' => '203.0.113.9' }

    get course_registrations_path, env: remote
    assert_response :not_found
    get timetable_upload_path(upload), env: remote
    assert_response :not_found
    assert_no_difference 'TimetableUpload.count' do
      post timetable_uploads_path, params: { semester: '前期' }, env: remote
    end
    assert_response :not_found
    patch update_rows_timetable_upload_path(upload), env: remote
    assert_response :not_found
    post commit_timetable_upload_path(upload), env: remote
    assert_response :not_found
    get page_image_timetable_upload_path(upload, 1), env: remote
    assert_response :not_found
  end
end

