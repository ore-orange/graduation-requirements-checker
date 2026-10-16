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

  def update_row(upload, row, changes, confirmed:)
    values = row.slice(*TimetableUploadRow::EDITABLE).merge(changes)
    patch timetable_upload_row_path(upload, row), params: { row: values, confirmed: confirmed }, env: ENV_LOCAL
  end

  def create_upload
    upload_pdf
    TimetableUpload.order(:id).last
  end

  test 'tab is shown in the navigation and lists registered offerings' do
    TimetableImport::Importer.new([{ '学期' => '前期', '講義コード' => '1', '科目番号' => '工共100', '科目名' => '工学基礎演習', '単位' => '2',
                                     '必修選択' => '必修', '受講年次' => '1', '曜日' => '金', '時限' => '2・3', '開講区分' => '1Q',
                                     '要確認' => '' }]).call(apply: true)

    get course_registrations_path, env: ENV_LOCAL

    assert_response :success
    assert_select 'nav a[aria-current=page]', text: '授業登録'
    assert_select 'td', text: '工学基礎演習'
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

  test 'cannot commit until every row is confirmed' do
    upload = create_upload

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select 'button[disabled]', text: '保存する', minimum: 1
    assert_select 'button:not([disabled])', text: '保存する', count: 0

    assert_no_difference 'CourseOffering.count' do
      post commit_timetable_upload_path(upload), env: ENV_LOCAL
    end
    assert_match '未確認', flash[:alert]
    assert TimetableUpload.exists?(upload.id)
  end

  test 'editing and confirming rows then committing saves and clears the upload' do
    upload = create_upload
    row = upload.rows.first

    update_row(upload, row, { 'weekday' => '月' }, confirmed: '1')
    assert_predicate row.reload, :confirmed
    assert_equal '月', row.weekday

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select 'button:not([disabled])', text: '保存する', minimum: 1

    assert_difference ['Course.count', 'CourseOffering.count'], 1 do
      post commit_timetable_upload_path(upload), env: ENV_LOCAL
    end
    assert_redirected_to course_registrations_path
    assert_equal '月', CourseOffering.find_by!(lecture_code: '610000071').weekday
    assert_not TimetableUpload.exists?(upload.id)
  end

  test 'update result is shown as a fixed toast, errors stay until closed' do
    upload = create_upload
    row = upload.rows.first

    update_row(upload, row, { 'weekday' => '月' }, confirmed: '0')
    follow_redirect!
    assert_select '[role=status][data-controller=toast]', text: /1行目を更新しました/

    update_row(upload, row, { 'period_text' => '4(・5)' }, confirmed: '1')
    follow_redirect!
    assert_select '[role=alert][data-controller=toast]', text: /確認済みにできません/
    assert_select '[role=alert][data-toast-auto-dismiss-value]', count: 0
  end

  test 'a row with invalid values cannot be confirmed' do
    upload = create_upload
    row = upload.rows.first

    update_row(upload, row, { 'period_text' => '4(・5)' }, confirmed: '1')

    assert_not row.reload.confirmed
    assert_equal '4(・5)', row.period_text
    assert_match '確認済みにできません', flash[:alert]
  end

  test 'confirm all only confirms rows without problems' do
    upload = nil
    TimetableImport::PdfParser.stub(:extract_xml, timetable_xml + timetable_xml(periods: '4(・5)')) do
      upload = TimetableUpload.build_from_pdf('unused', semester: '前期', filename: 'a.pdf')
    end
    flagged = upload.rows.where.not(review_reason: nil)

    post confirm_all_timetable_upload_path(upload), env: ENV_LOCAL

    assert_equal 1, upload.rows.where(confirmed: true).count
    assert_equal flagged.pluck(:id), upload.rows.where(confirmed: false).pluck(:id)
  end

  test 'opening a missing upload goes back to the list with a message' do
    get timetable_upload_path(0), env: ENV_LOCAL

    assert_redirected_to course_registrations_path
    assert_match '見つかりません', flash[:alert]
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

  test 'confirmation screen shows 30 rows per page' do
    upload = create_large_upload

    get timetable_upload_path(upload), env: ENV_LOCAL
    assert_select 'tbody tr', 30
    assert_select 'nav[aria-label=ページ送り] a', text: '2'
    # 1ページ目では « と ‹ は押せず、› と » は押せる
    assert_select 'nav[aria-label=ページ送り] span[aria-disabled=true]', text: '<<'
    assert_select 'nav[aria-label=ページ送り] span[aria-disabled=true]', text: '<'
    assert_select 'nav[aria-label=ページ送り] a[href=?]', timetable_upload_path(upload, page: 2), text: '>'
    assert_select 'nav[aria-label=ページ送り] a[href=?]', timetable_upload_path(upload, page: 2), text: '>>'
    assert_select 'input[value=科目30]', 1
    assert_select 'input[value=科目31]', 0

    get timetable_upload_path(upload, page: 2), env: ENV_LOCAL
    assert_select 'tbody tr', 5
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
    assert_select 'tbody tr', 5
  end

  test 'updating a row returns to the same page' do
    upload = create_large_upload
    row = upload.rows.find_by!(position: 32)

    patch timetable_upload_row_path(upload, row), env: ENV_LOCAL,
                                                  params: { page: 2, confirmed: '1',
                                                            row: row.slice(*TimetableUploadRow::EDITABLE) }

    assert_redirected_to timetable_upload_path(upload, page: 2)
    assert_predicate row.reload, :confirmed
  end

  test 'confirm all covers every page, not just the visible one' do
    upload = create_large_upload

    post confirm_all_timetable_upload_path(upload), params: { page: 2 }, env: ENV_LOCAL

    assert_redirected_to timetable_upload_path(upload, page: 2)
    assert_equal 35, upload.rows.where(confirmed: true).count
  end

  test 'saved offerings list is paginated too' do
    rows = Array.new(35) do |index|
      { '学期' => '前期', '講義コード' => format('%09d', index), '科目番号' => "工共#{index}", '科目名' => "科目#{index}",
        '単位' => '2', '必修選択' => '必修', '受講年次' => '1', '曜日' => '月', '時限' => '1', '開講区分' => '半年',
        '要確認' => '' }
    end
    TimetableImport::Importer.new(rows).call(apply: true)

    get course_registrations_path, env: ENV_LOCAL
    assert_select '#registered-heading ~ div nav', minimum: 1
    assert_select 'tbody tr', 30
    get course_registrations_path(page: 2), env: ENV_LOCAL
    assert_select 'tbody tr', 5
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
    post commit_timetable_upload_path(upload), env: remote
    assert_response :not_found
  end
end

