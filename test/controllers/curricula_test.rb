# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require 'tempfile'

# gs と Gemini は動かさない。PdfPages と読み取りを差し替えて、画面の流れを見る。
class CurriculaTest < ActionDispatch::IntegrationTest
  setup do
    host! 'localhost'
    sign_in_as(User.create!(email: 'curriculum-importer@example.test', password: 'a-test-password'))
    department = Faculty.create!(name: '取り込み学部').departments.create!(name: '取り込み学科')
    @program = department.programs.create!(name: '取り込みコース')
  end

  def fake_render(_pdf, _page, path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, 'png')
    path
  end

  def upload(content: "%PDF-1.4\nbody", **overrides)
    file = Tempfile.new(['binran', '.pdf'])
    file.write(content)
    file.rewind
    params = { program_id: @program.id, admission_year: 2025, page_range: '11',
               pdf: Rack::Test::UploadedFile.new(file.path, 'application/pdf') }.merge(overrides)
    PdfPages.stub(:page_count, 14) do
      PdfPages.stub(:render_page, method(:fake_render)) do
        PdfPages.stub(:page_text, '卒業要件') { post curricula_path, params: params }
      end
    end
  ensure
    file&.close!
  end

  def draft(document: {}, pages: nil)
    pages ||= [{ 'page' => 11, 'text' => '卒業要件', 'status' => 'pending', 'error' => nil }]
    Curriculum.create!(slug: Curriculum.slug_for(@program), admission_year: 2025, document: document,
                       source_filename: 'binran.pdf', pages: pages)
  end

  test '取り込みの画面に、アップロードの欄と下書きの一覧を出す' do
    existing = draft

    get curricula_path

    assert_response :success
    assert_select "form[action='#{curricula_path}'] select[name='program_id'] option", text: '取り込みコース'
    assert_select "a[href='#{curriculum_path(existing)}']", text: '開く'
    assert_select 'nav a[aria-current=page]', text: '便覧の取り込み'
  end

  test 'PDFを上げると下書きを作り、下書きの画面へ進む' do
    assert_difference('Curriculum.drafts.count', 1) { upload }

    created = Curriculum.drafts.last
    assert_redirected_to curriculum_path(created)
    assert_equal "program_#{@program.id}", created.slug
    assert_equal [11], created.pages.pluck('page')
  end

  test '選び忘れ・PDFでないファイル・読めないページ指定は、下書きを作らずに理由を出す' do
    [{ program_id: '' }, { admission_year: 1999 }, { content: 'not a pdf' }, { page_range: '99' }].each do |overrides|
      assert_no_difference('Curriculum.count', overrides.inspect) { upload(**overrides) }
      assert_redirected_to curricula_path
      assert flash[:alert].present?, overrides.inspect
    end
  end

  test '下書きの画面に、ページの状態と読み取った内容を出す' do
    document = { 'categories' => [{ 'key' => 'health', 'label' => '健康運動系科目' }], 'roles' => [],
                 'rules' => [{ 'id' => 'health', 'type' => 'credit_sum', 'label' => '健康運動系', 'categories' => ['health'],
                               'required_credits' => 2 }],
                 'display' => { 'total_credits' => 130, 'groups' => [{ 'id' => 'common', 'title' => '共通教育',
                                                                       'required_credits' => 30, 'rows' => [] }] } }
    shown = draft(document: document, pages: [{ 'page' => 11, 'status' => 'failed', 'error' => 'HTTP 503' }])

    GeminiClient.stub(:available?, true) { get curriculum_path(shown) }

    assert_response :success
    assert_select '#page-11', text: /読み取りに失敗/
    assert_select '#page-11', text: /HTTP 503/
    assert_select "form[action='#{read_page_curriculum_path(shown, page: 11)}'] button", text: '読み直す'
    assert_select 'li', text: /健康運動系科目の合計 2単位以上/
    assert_select 'h3', text: /130単位/
  end

  test 'APIキーが無ければ、読み取りのボタンを出さずに理由を出す' do
    GeminiClient.stub(:available?, false) { get curriculum_path(draft) }

    assert_select 'button', text: '読み取る', count: 0
    assert_select 'p', text: /管理担当者に連絡/
  end

  test '読み取りのボタンは、ページを読み取り中にしてジョブに渡し、すぐ画面に戻る' do
    target = draft

    GeminiClient.stub(:available?, true) do
      assert_enqueued_with(job: ReadRequirementsPageJob, args: [target.id, 11]) do
        post read_page_curriculum_path(target, page: 11)
      end
    end

    assert_redirected_to curriculum_path(target, anchor: 'page-11')
    assert_equal 'reading', target.reload.page_entry(11)['status']
  end

  test '読み取り中のページは、もう一度押してもジョブを増やさない' do
    target = draft(pages: [{ 'page' => 11, 'status' => 'reading', 'started_at' => Time.current.iso8601 }])

    GeminiClient.stub(:available?, true) do
      assert_no_enqueued_jobs { post read_page_curriculum_path(target, page: 11) }
    end
    assert_equal '11ページは読み取り中です。', flash[:notice]
  end

  test '状態の問い合わせに、ページごとの状態を返す' do
    target = draft(pages: [{ 'page' => 10, 'status' => 'reading', 'started_at' => Time.current.iso8601 },
                           { 'page' => 11, 'status' => 'read' }])

    get status_curriculum_path(target)

    assert_equal({ 'reading' => true, 'pages' => [{ 'page' => 10, 'status' => 'reading' },
                                                  { 'page' => 11, 'status' => 'read' }] }, response.parsed_body)
  end

  test '読み取り中の画面は、ボタンの代わりに案内を出し、状態の問い合わせを仕掛ける' do
    target = draft(pages: [{ 'page' => 11, 'status' => 'reading', 'started_at' => Time.current.iso8601 }])

    GeminiClient.stub(:available?, true) { get curriculum_path(target) }

    url = status_curriculum_path(target)
    assert_select "[data-controller='reading-status'][data-reading-status-url-value='#{url}']"
    assert_select '#page-11 button', count: 0
    assert_select '#page-11', text: /自動で結果が出ます/
  end

  test '読み取り中のまま止まったページは、中断として読み直せる' do
    target = draft(pages: [{ 'page' => 11, 'status' => 'reading', 'started_at' => 1.hour.ago.iso8601 }])

    GeminiClient.stub(:available?, true) { get curriculum_path(target) }

    assert_select "[data-controller='reading-status']", count: 0
    assert_select '#page-11', text: /中断/
    assert_select '#page-11 button', text: '読み直す'
  end

  test '下書きに無いページは読まない' do
    target = draft

    GeminiClient.stub(:available?, true) { post read_page_curriculum_path(target, page: 99) }

    assert_redirected_to curriculum_path(target)
    assert flash[:alert].present?
  end

  test 'ページ画像を返し、無いページは404にする' do
    shown = draft
    fake_render(nil, 11, shown.images_dir.join('p11.png'))

    get page_image_curriculum_path(shown, page: 11)
    assert_response :success
    assert_equal 'image/png', response.media_type

    get page_image_curriculum_path(shown, page: 12)
    assert_response :not_found
  end

  test '下書きを削除できる。公開済みの便覧はこの画面では開かない' do
    target = draft
    assert_difference('Curriculum.count', -1) { delete curriculum_path(target) }
    assert_redirected_to curricula_path

    get curriculum_path(curricula(:intelligent_informatics2024))
    assert_redirected_to curricula_path
  end
end

