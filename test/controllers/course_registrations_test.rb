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

  def upload_pdf(semester: '前期', xml: timetable_xml, content: "%PDF-1.4\nbody")
    file = Tempfile.new(['timetable', '.pdf'])
    file.write(content)
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, 'application/pdf')
    TimetableImport::PdfParser.stub(:extract_xml, xml) do
      post timetable_uploads_path, params: { semester: semester, pdf: upload }, env: ENV_LOCAL
    end
  ensure
    file&.close!
  end

  # 確認画面の「更新」と同じ形で送る。changesは { 行 => { 項目 => 値 } }、confirmedはチェックを入れる行。
  def update_rows(upload, changes: {}, confirmed: [], page: nil, operation: 'update')
    rows = changes.to_h { |row, values| [row.id, row.slice(*TimetableUploadRow::EDITABLE).merge(values)] }
    params = { rows: rows, confirmed: confirmed.to_h { |row| [row.id, '1'] }, operation: operation }
    params[:page] = page if page
    patch update_rows_timetable_upload_path(upload), params: params, env: ENV_LOCAL
  end

  def create_upload
    upload_pdf
    TimetableUpload.order(:id).last
  end

  def create_large_upload(count = 35)
    upload = TimetableUpload.create!(semester: '前期', source_filename: 'big.pdf')
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
    TimetableImport::Importer.new([{ '学期' => '前期', '講義コード' => '1', '科目番号' => '工共100', '科目名' => '工学基礎演習',
                                     '単位' => '2', '必修選択' => '必修', '受講年次' => '1', '曜日' => '金', '時限' => '2・3',
                                     '開講区分' => '1Q', '要確認' => '' }]).call(apply: true)

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

  test 'upload rejects files that are not pdfs and unknown semesters' do
    assert_no_difference 'TimetableUpload.count' do
      upload_pdf(content: 'not a pdf')
      assert_match 'PDFファイル', flash[:alert]
      upload_pdf(semester: '通年')
      assert_match '前期か後期', flash[:alert]
    end
  end

  test 'upload reports a pdf without any course rows' do
    assert_no_difference 'TimetableUpload.count' do
      upload_pdf(xml: "<page>\n</page>")
    end
    assert_match '科目の行を見つけられません', flash[:alert]
  end

  test 'fixed-value fields are selects and the page has one save button in the footer' do
    upload = create_upload
    row = upload.rows.first

    get timetable_upload_path(upload), env: ENV_LOCAL

    %w[requirement_type grade_text weekday period_text term_type].each do |field|
      assert_select "select[name='rows[#{row.id}][#{field}]']"
    end
    assert_select "input[type=number][name='rows[#{row.id}][credits]']"
    assert_select 'button', text: '保存する', count: 1
    assert_select 'button', text: 'チェックした行を確認済みにして更新'
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
    assert_select '[role=status]', text: /1行を更新しました/

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

  test 'updating with no edits and no checks says nothing changed' do
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => {} })
    follow_redirect!

    assert_select '[role=status]', text: /変更はありません/
    assert_select '[role=status]', text: /更新しました/, count: 0
  end

  test 'success messages dismiss themselves and sit at the right edge' do
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'weekday' => '月' } })
    follow_redirect!

    assert_select 'div.right-4 [role=status][data-toast-auto-dismiss-value="5000"]'
  end

  test 'confirm all covers every page but skips rows flagged for review' do
    upload = create_large_upload
    flagged = upload.rows.find_by!(position: 34)
    flagged.update!(review_reason: '時限が不明')

    update_rows(upload, operation: 'confirm_all', page: 2)

    assert_redirected_to timetable_upload_path(upload, page: 2)
    assert_equal 34, upload.rows.where(confirmed: true).count
    assert_not flagged.reload.confirmed
  end

  test 'confirmation screen shows 30 rows per page with pagination only at the bottom' do
    upload = create_large_upload

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select 'tbody[id^=row-]', 30
    assert_select 'input[value=科目30]', 1
    assert_select 'input[value=科目31]', 0
    assert_select 'nav[aria-label=ページ送り]', 1
    assert_select 'nav[aria-label=ページ送り] span[aria-disabled=true]', text: '<<'
    assert_select 'nav[aria-label=ページ送り] span[aria-disabled=true]', text: '<'
    assert_select 'nav[aria-label=ページ送り] a[href=?]', timetable_upload_path(upload, page: 2), text: '>'
    assert_select 'nav[aria-label=ページ送り] a[href=?]', timetable_upload_path(upload, page: 2), text: '>>'

    get timetable_upload_path(upload, page: 2), env: ENV_LOCAL
    assert_select 'tbody[id^=row-]', 5
    assert_select 'input[value=科目31]', 1
    assert_select 'span[aria-current=page]', text: '2', minimum: 1
    assert_select 'nav[aria-label=ページ送り] a[href=?]', timetable_upload_path(upload, page: 1), text: '<<'
    assert_select 'nav[aria-label=ページ送り] a[href=?]', timetable_upload_path(upload, page: 1), text: '<'
    assert_select 'nav[aria-label=ページ送り] span[aria-disabled=true]', text: '>>'
  end

  test 'out of range page falls back to the last page' do
    upload = create_large_upload

    get timetable_upload_path(upload, page: 99), env: ENV_LOCAL
    assert_response :success
    assert_select 'tbody[id^=row-]', 5
  end

  test 'updating rows returns to the same page' do
    upload = create_large_upload
    row = upload.rows.find_by!(position: 32)

    update_rows(upload, changes: { row => {} }, confirmed: [row], page: 2)

    assert_redirected_to timetable_upload_path(upload, page: 2)
    assert_predicate row.reload, :confirmed
  end

  test 'only rows sent from the page are touched' do
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
    TimetableImport::Importer.new(rows).call(apply: true)

    get course_registrations_path, env: ENV_LOCAL
    assert_select 'nav[aria-label=ページ送り]', 1
    assert_select 'tbody tr', 30
    get course_registrations_path(page: 2), env: ENV_LOCAL
    assert_select 'tbody tr', 5
  end

  test 'a registered course with the same name and number needs an explicit choice' do
    registered_course
    upload = create_upload
    row = upload.rows.first

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select "select[name='rows[#{row.id}][course_choice]'] option", text: /既存の講義として扱う/
    assert_select "select[name='rows[#{row.id}][course_choice]'] option", text: /別の講義として新しく登録する/

    update_rows(upload, changes: { row => {} }, confirmed: [row])
    assert_not row.reload.confirmed
    follow_redirect!
    assert_select "tbody#row-#{row.id} td", text: /同じ講義として扱うか、別の講義として登録するか/
  end

  test 'choosing the existing course links the offering without creating a course' do
    course = registered_course
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'course_choice' => course.id.to_s } }, confirmed: [row])
    assert_predicate row.reload, :confirmed

    assert_no_difference 'Course.count' do
      assert_difference 'CourseOffering.count', 1 do
        post commit_timetable_upload_path(upload), env: ENV_LOCAL
      end
    end
    assert_equal course, CourseOffering.find_by!(lecture_code: '610000071').course
  end

  test 'choosing a new course registers a separate course even with the same name and number' do
    registered_course
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'course_choice' => 'new' } }, confirmed: [row])
    assert_predicate row.reload, :confirmed

    assert_difference 'Course.count', 1 do
      post commit_timetable_upload_path(upload), env: ENV_LOCAL
    end
    assert_equal 2, Course.where(course_number: '工共100', name: '工学基礎演習').count
  end

  test 'a choice that is not among the candidates is ignored' do
    registered_course
    other = Course.create!(course_number: '別', name: '別の講義', credits: 1)
    upload = create_upload
    row = upload.rows.first

    update_rows(upload, changes: { row => { 'course_choice' => other.id.to_s } }, confirmed: [row])

    assert_nil row.reload.course_id
    assert_not row.confirmed
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
  end
end

