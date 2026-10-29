# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require 'tempfile'

# 便覧PDFを上げて下書きを作り、読むページを指定する画面。読み取りやAIはこのタスクの範囲外。
class CurriculaTest < ActionDispatch::IntegrationTest
  ENV_LOCAL = { 'REMOTE_ADDR' => '127.0.0.1' }.freeze
  REAL_PDF = Rails.root.join('docs/kogaku_chinot_y24.pdf')

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
  end

  teardown do
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
  end

  def pdf_fixture = Rack::Test::UploadedFile.new(REAL_PDF, 'application/pdf')

  def text_upload(content, name: 'handbook.pdf')
    file = Tempfile.new(['handbook', '.pdf'])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, 'application/pdf', original_filename: name)
  end

  def upload_params(**overrides)
    { curriculum: { slug: 'x', admission_year: 2025, faculty_name: '工学部',
                    department_name: '工学科 知能情報コース', file: pdf_fixture }.merge(overrides) }
  end

  def blank_pages(count, kind: 'skip')
    Curriculum.blank_pages(count).map { |page| page.merge('kind' => kind) }
  end

  def draft(pages: blank_pages(5))
    Curriculum.create!(slug: 'x', admission_year: 2025, faculty_name: '工学部', department_name: '工学科 知能情報コース',
                       source_filename: 'handbook.pdf', pages: pages)
  end

  test 'PDFを上げると下書きができてページ一覧が出る' do
    post curricula_path, params: upload_params, env: ENV_LOCAL

    curriculum = Curriculum.last
    assert_redirected_to curriculum_path(curriculum)
    assert_not_predicate curriculum, :published?
    assert_equal 14, curriculum.pages.size
    assert_equal %w[skip], curriculum.pages.pluck('kind').uniq
    assert_equal({ 'page' => 1, 'kind' => 'skip', 'status' => 'pending', 'error' => nil, 'text' => nil },
                 curriculum.pages.first)
    assert_equal (1..14).to_a, curriculum.pages.pluck('page')
    assert_equal 'x', curriculum.slug
    assert_equal 2025, curriculum.admission_year
    assert_equal '工学部', curriculum.faculty_name
    assert_equal '工学科 知能情報コース', curriculum.department_name
    assert_equal 'kogaku_chinot_y24.pdf', curriculum.source_filename
    assert_nil curriculum.import_error
    assert_equal({}, curriculum.document)
  end

  test '作った下書きの確認画面は、空の文書でも開ける' do
    post curricula_path, params: upload_params, env: ENV_LOCAL
    follow_redirect!

    assert_response :success
    assert_select 'input[type=radio][name^="pages["]', count: 14 * 3
    assert_select 'input[type=radio][value=skip][checked]', count: 14
  end

  test 'slug と年度と学部・学科とPDFが欠けていたら作らない' do
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: { curriculum: { slug: '' } }, env: ENV_LOCAL
    end
    assert_redirected_to requirements_path
    assert_predicate flash[:alert], :present?

    { slug: '', admission_year: '', faculty_name: '', department_name: '', file: nil }.each do |field, value|
      assert_no_difference('Curriculum.count', "#{field} が欠けていても作ってしまった") do
        post curricula_path, params: upload_params(field => value), env: ENV_LOCAL
      end
      assert_redirected_to requirements_path
    end
  end

  test 'curriculum がハッシュでなくても落ちず、何も作らない' do
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: { curriculum: 'x' }, env: ENV_LOCAL
    end
    assert_redirected_to requirements_path
    assert_predicate flash[:alert], :present?
  end

  test '同じ slug と年度の公開済みがあっても、下書きを作れて、公開済みは変わらない' do
    published = Curriculum.published.first
    before = published.attributes

    assert_difference('Curriculum.count', 1) do
      post curricula_path, params: upload_params(slug: published.slug, admission_year: published.admission_year),
                           env: ENV_LOCAL
    end

    draft = Curriculum.drafts.last
    assert_equal [published.slug, published.admission_year], [draft.slug, draft.admission_year]
    found = Curriculum.published.find_by(slug: published.slug, admission_year: published.admission_year)
    assert_equal published.id, found.id
    assert_equal before, found.attributes
    assert_not_equal found.id, draft.id
  end

  test '入学年度は2000年から今年+2までの下書きだけ作る' do
    upper = Time.zone.today.year + 2
    [1999, 5, upper + 1].each do |year|
      assert_no_difference('Curriculum.count', "#{year} を受けてしまった") do
        post curricula_path, params: upload_params(admission_year: year), env: ENV_LOCAL
      end
      assert_redirected_to requirements_path
    end
    [2000, upper].each do |year|
      assert_difference('Curriculum.count', 1, "#{year} を受けなかった") do
        post curricula_path, params: upload_params(admission_year: year), env: ENV_LOCAL
      end
    end
  end

  test 'slug は半角英小文字で始まる形だけを受ける' do
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: upload_params(slug: 'Bad Slug'), env: ENV_LOCAL
    end
    assert_redirected_to requirements_path
  end

  test 'PDFでないファイルは作らない' do
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: upload_params(file: text_upload('plain text')), env: ENV_LOCAL
    end
    assert_redirected_to requirements_path
    assert_match(/PDF/, flash[:alert])
  end

  test '大きすぎるPDFは作らない' do
    big = text_upload("%PDF-1.4\n#{'a' * (CurriculaController::MAX_PDF_BYTES + 1)}")
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: upload_params(file: big), env: ENV_LOCAL
    end
    assert_match(/MB以下/, flash[:alert])
  end

  test 'ページ数を数えられなくても、失敗を記録して下書きは作る' do
    boom = ->(_path) { raise CurriculaController::PageCountError, 'Ghostscript(gs)が見つかりません。' }
    CurriculaController.stub(:count_pages, boom) do
      assert_difference('Curriculum.count', 1) do
        post curricula_path, params: upload_params, env: ENV_LOCAL
      end
    end

    curriculum = Curriculum.last
    assert_redirected_to curriculum_path(curriculum)
    assert_empty curriculum.pages
    assert_equal 'Ghostscript(gs)が見つかりません。', curriculum.import_error
    follow_redirect!
    assert_select '[role=alert]', text: /Ghostscript/
  end

  test '壊れたPDFは、ページ数を数えられなかった下書きになる' do
    assert_difference('Curriculum.count', 1) do
      post curricula_path, params: upload_params(file: text_upload("%PDF-1.4\nbroken")), env: ENV_LOCAL
    end

    assert_empty Curriculum.last.pages
    assert_predicate Curriculum.last.import_error, :present?
  end

  test 'ページ数を数えられなかった下書きは、ページ数を手で指定できる' do
    curriculum = draft(pages: [])

    patch curriculum_path(curriculum), params: { page_count: '3' }, env: ENV_LOCAL

    assert_redirected_to curriculum_path(curriculum)
    assert_equal [1, 2, 3], curriculum.reload.pages.pluck('page')
    assert_equal %w[skip], curriculum.pages.pluck('kind').uniq
  end

  test 'ページ数の指定は、すでにページがある下書きや不正な値では何もしない' do
    curriculum = draft
    patch curriculum_path(curriculum), params: { page_count: '3' }, env: ENV_LOCAL
    assert_equal 5, curriculum.reload.pages.size

    empty = draft(pages: [])
    %w[0 -1 abc 100000].each do |value|
      patch curriculum_path(empty), params: { page_count: value }, env: ENV_LOCAL
      assert_empty empty.reload.pages, "#{value} を受けてしまった"
    end
  end

  test '下書きは消せる' do
    curriculum = draft

    assert_difference('Curriculum.count', -1) do
      delete curriculum_path(curriculum), env: ENV_LOCAL
    end
    assert_nil Curriculum.find_by(id: curriculum.id)
    assert_redirected_to requirements_path
  end

  test '公開済みの便覧はこの画面から消せず、開けず、直せない' do
    published = Curriculum.published.first

    assert_no_difference('Curriculum.count') { delete curriculum_path(published), env: ENV_LOCAL }
    assert_redirected_to requirements_path

    get curriculum_path(published), env: ENV_LOCAL
    assert_redirected_to requirements_path

    before = published.reload.pages
    patch curriculum_path(published), params: { pages: { '1' => 'courses' } }, env: ENV_LOCAL
    assert_redirected_to requirements_path
    assert_equal before, published.reload.pages
  end

  test '存在しない下書きは一覧に戻す' do
    get curriculum_path(0), env: ENV_LOCAL
    assert_redirected_to requirements_path
    assert_predicate flash[:alert], :present?
  end

  test 'ページの種別を変えられる' do
    curriculum = draft

    patch curriculum_path(curriculum), params: { pages: { '3' => 'requirements', '4' => 'courses' } }, env: ENV_LOCAL

    assert_redirected_to curriculum_path(curriculum)
    pages = curriculum.reload.pages
    assert_equal 'requirements', pages.find { |page| page['page'] == 3 }['kind']
    assert_equal 'courses', pages.find { |page| page['page'] == 4 }['kind']
    changed = [3, 4]
    assert_equal %w[skip], pages.reject { |page| changed.include?(page['page']) }.pluck('kind').uniq
    assert_equal %w[pending], pages.pluck('status').uniq
  end

  test '種別を送られなかったページは、いまの種別のまま残る' do
    curriculum = draft(pages: blank_pages(3, kind: 'courses'))

    patch curriculum_path(curriculum), params: { pages: { '2' => 'skip' } }, env: ENV_LOCAL

    assert_equal %w[courses skip courses], curriculum.reload.pages.pluck('kind')
  end

  test '知らない種別や存在しないページは受けず、何も変えない' do
    curriculum = draft

    patch curriculum_path(curriculum), params: { pages: { '1' => 'courses', '2' => 'bogus' } }, env: ENV_LOCAL
    assert_redirected_to curriculum_path(curriculum)
    assert_predicate flash[:alert], :present?
    assert_equal %w[skip], curriculum.reload.pages.pluck('kind').uniq

    patch curriculum_path(curriculum), params: { pages: { '99' => 'courses' } }, env: ENV_LOCAL
    assert_equal %w[skip], curriculum.reload.pages.pluck('kind').uniq
    assert_equal 5, curriculum.pages.size
  end

  test 'ナビは確認画面でも卒業要件の確認が選ばれている' do
    get curriculum_path(draft), env: ENV_LOCAL

    assert_response :success
    assert_select 'a[aria-current=page]', text: '卒業要件の確認'
    assert_select 'a[aria-current=page]', count: 1
  end

  test '確認画面は、下書きの情報とページごとの種別を出す' do
    curriculum = draft(pages: blank_pages(5).each_with_index.map do |page, i|
      i == 2 ? page.merge('kind' => 'requirements') : page
    end)

    get curriculum_path(curriculum), env: ENV_LOCAL

    assert_select 'body', text: /下書き/
    assert_select 'body', text: /2025/
    assert_select 'form[action=?]', curriculum_path(curriculum)
    assert_select 'input[type=radio][name="pages[3]"][value=requirements][checked]', count: 1
    assert_select 'input[type=radio][name="pages[1]"][value=skip][checked]', count: 1
    assert_select 'label', text: /科目表/
    assert_select 'label', text: /要件表/
    assert_select 'label', text: /読まない/
  end

  test '/requirements は、学生の便覧に加えて、公開済みと下書きを別々に一覧し、アップロードの入口を出す' do
    mine = draft
    other = Curriculum.create!(slug: 'other', admission_year: 2026, faculty_name: '工学部', department_name: 'X',
                               source_filename: 'o.pdf', pages: blank_pages(2))
    DemoData.load!

    get requirements_path, env: ENV_LOCAL

    assert_response :success
    assert_select 'section[data-group]', minimum: 1
    assert_select 'section[data-published-curricula] li', minimum: 1
    assert_select 'section[data-published-curricula] a[href=?]', curriculum_path(mine), count: 0
    assert_select 'section[data-draft-curricula] li', count: 2
    assert_select 'section[data-draft-curricula] a[href=?]', curriculum_path(mine)
    assert_select 'section[data-draft-curricula] a[href=?]', curriculum_path(other)
    assert_select 'form[action=?][enctype="multipart/form-data"]', curricula_path do
      assert_select 'input[name="curriculum[slug]"]'
      assert_select 'input[name="curriculum[admission_year]"]'
      assert_select 'input[name="curriculum[faculty_name]"]'
      assert_select 'input[name="curriculum[department_name]"]'
      assert_select 'input[type=file][name="curriculum[file]"][accept="application/pdf"]'
    end
  end

  test 'ページ数を数えられなかった下書きは、一覧で要確認と分かる' do
    ok = draft
    failed = draft(pages: [])
    failed.update!(import_error: 'Ghostscript(gs)が見つかりません。')
    DemoData.load!

    get requirements_path, env: ENV_LOCAL

    assert_select 'section[data-draft-curricula] li', count: 2
    assert_select %(section[data-draft-curricula] li:has(a[href="#{curriculum_path(failed)}"])), text: /要確認/
    assert_select %(section[data-draft-curricula] li:has(a[href="#{curriculum_path(ok)}"])), text: /要確認/, count: 0
  end

  test '下書きがないときは、下書きの一覧を出さない' do
    DemoData.load!
    get requirements_path, env: ENV_LOCAL

    assert_select 'section[data-draft-curricula]', count: 0
    assert_select 'section[data-published-curricula] li', minimum: 1
  end

  test '外部からは開けない' do
    host! 'example.com'
    post curricula_path, params: upload_params
    assert_response :not_found
    get curriculum_path(draft)
    assert_response :not_found
  end

  test 'ルートの形が決まっている' do
    assert_routing({ method: 'post', path: '/curricula/1/publish' }, controller: 'curricula', action: 'publish',
                                                                     id: '1')
    assert_routing({ method: 'post', path: '/curricula/1/pages/2/read' },
                   controller: 'curricula', action: 'read_page', id: '1', page: '2')
    assert_routing({ method: 'patch', path: '/curricula/1/update_courses' },
                   controller: 'curricula', action: 'update_courses', id: '1')
    assert_routing({ method: 'patch', path: '/curricula/1/update_rules' },
                   controller: 'curricula', action: 'update_rules', id: '1')
    assert_routing({ method: 'get', path: '/curricula/1/page_image/2' },
                   controller: 'curricula', action: 'page_image', id: '1', page: '2')
  end
end

