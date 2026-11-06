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
    { curriculum: { admission_year: 2025, faculty_name: '工学部',
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
    assert_equal({ 'page' => 1, 'kind' => 'skip', 'status' => 'pending', 'error' => nil },
                 curriculum.pages.first.except('text'))
    assert_equal (1..14).to_a, curriculum.pages.pluck('page')
    assert_equal 'intelligent_informatics', curriculum.slug
    assert_equal 2025, curriculum.admission_year
    assert_equal '工学部', curriculum.faculty_name
    assert_equal '工学科 知能情報コース', curriculum.department_name
    assert_equal 'kogaku_chinot_y24.pdf', curriculum.source_filename
    assert_nil curriculum.import_error
    assert_equal({}, curriculum.document)
  end

  test '上げたときに、ページ画像とページごとのテキストを取り出して残す' do
    post curricula_path, params: upload_params, env: ENV_LOCAL

    curriculum = Curriculum.last
    assert_empty Dir.children(curriculum.images_dir).grep_v(/\Ap\d+\.png\z/), 'PNG以外(元のPDFなど)を置いてはいけない'
    assert_equal (1..14).map { |n| "p#{n}.png" }.sort, Dir.children(curriculum.images_dir).sort
    assert_equal 14, curriculum.pages.pluck('text').size
    assert(curriculum.pages.all? { |page| page['text'].is_a?(String) })
    assert_includes curriculum.pages[2]['text'], '工学基礎演習'
    assert_equal %w[skip], curriculum.pages.pluck('kind').uniq
    assert_nil curriculum.import_error
  end

  test '元のPDFはどこにも保管しない' do
    post curricula_path, params: upload_params, env: ENV_LOCAL

    stored = Dir.glob(Curriculum.images_root.join('**/*')).select { |path| File.file?(path) }
    assert_empty(stored.grep_v(/\.png\z/))
    assert_empty Curriculum.images_root.glob('**/*.pdf')
  end

  test '画像が作れなくても、テキストを取り出して下書きは作り、失敗を記録する' do
    CurriculumImport::PageSource.stub(:render_images, 0) do
      assert_difference('Curriculum.count', 1) do
        post curricula_path, params: upload_params, env: ENV_LOCAL
      end
    end

    curriculum = Curriculum.last
    assert_redirected_to curriculum_path(curriculum)
    assert_equal 14, curriculum.pages.size
    assert_includes curriculum.pages[2]['text'], '工学基礎演習'
    assert_match(/14ページ中0ページ/, curriculum.import_error)
  end

  test '文字が取り出せなくても、画像つきで下書きは作り、読めなかったページを記録する' do
    failed = CurriculumImport::PageSource::TextResult.new(Array.new(14, ''), [3, 5])
    CurriculumImport::PageSource.stub(:extract_texts, failed) do
      post curricula_path, params: upload_params, env: ENV_LOCAL
    end

    curriculum = Curriculum.last
    assert_equal 14, curriculum.pages.size
    assert_equal 14, Dir.glob(curriculum.images_dir.join('p*.png')).size
    assert_equal [''], curriculum.pages.pluck('text').uniq
    assert_match(/3・5ページ/, curriculum.import_error)
  end

  test '画像化が予期しない例外で落ちても、下書きは作る' do
    CurriculumImport::PageSource.stub(:render_images, ->(*) { raise IOError, 'disk full' }) do
      assert_difference('Curriculum.count', 1) do
        post curricula_path, params: upload_params, env: ENV_LOCAL
      end
    end

    assert_equal 14, Curriculum.last.pages.size
    assert_predicate Curriculum.last.import_error, :present?
  end

  test 'ページ画像を返せるのは下書きのPNGだけで、番号以外では引けない' do
    post curricula_path, params: upload_params, env: ENV_LOCAL
    curriculum = Curriculum.last

    get page_image_curriculum_path(curriculum, page: 3), env: ENV_LOCAL
    assert_response :success
    assert_equal 'image/png', response.media_type
    assert_equal curriculum.images_dir.join('p3.png').binread, response.body

    [0, 15, 'abc', '1e1'].each do |page|
      get page_image_curriculum_path(curriculum, page: page), env: ENV_LOCAL
      assert_response :not_found, "#{page} を返してしまった"
    end
  end

  test 'ページ画像は他の下書きの置き場や置き場の外のファイルを返さない' do
    mine = draft
    other = draft
    FileUtils.mkdir_p(other.images_dir)
    other.images_dir.join('p1.png').write('other')
    Rails.root.join('tmp/outside.png').write('outside')

    get page_image_curriculum_path(mine, page: 1), env: ENV_LOCAL
    assert_response :not_found
    ['..%2F..%2Foutside', "..%2F#{other.id}%2Fp1"].each do |page|
      get "/curricula/#{mine.id}/page_image/#{page}", env: ENV_LOCAL
      assert_includes [404, 400], response.status
    end
  ensure
    FileUtils.rm_f(Rails.root.join('tmp/outside.png'))
  end

  test '公開済みの便覧のページ画像は返さない' do
    published = Curriculum.published.first
    FileUtils.mkdir_p(published.images_dir)
    published.images_dir.join('p1.png').write('png')

    get page_image_curriculum_path(published, page: 1), env: ENV_LOCAL

    assert_redirected_to requirements_path_for(published)
  end

  test 'ページ画像は外部からは開けない' do
    curriculum = draft
    FileUtils.mkdir_p(curriculum.images_dir)
    curriculum.images_dir.join('p1.png').write('png')
    host! 'example.com'

    get page_image_curriculum_path(curriculum, page: 1)

    assert_response :not_found
  end

  test '下書きを消すと、画像も消える' do
    post curricula_path, params: upload_params, env: ENV_LOCAL
    curriculum = Curriculum.last
    assert_path_exists curriculum.images_dir

    delete curriculum_path(curriculum), env: ENV_LOCAL

    refute_path_exists curriculum.images_dir
  end

  test '作った下書きの確認画面は、空の文書でも開ける' do
    post curricula_path, params: upload_params, env: ENV_LOCAL
    follow_redirect!

    assert_response :success
    assert_select 'input[type=radio][name^="pages["]', count: 14 * 3
    assert_select 'input[type=radio][value=skip][checked]', count: 14
  end

  test '年度と学部・学科とPDFが欠けていたら作らない' do
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: { curriculum: { admission_year: '' } }, env: ENV_LOCAL
    end
    assert_redirected_to requirements_path
    assert_predicate flash[:alert], :present?

    chosen = requirements_path(faculty: '工学部', department: '工学科', course: '知能情報コース', admission_year: 2025)
    # 値が欠けていれば載せる選択が揃わないので素のパス。PDFだけが欠けているときは、選択が揃っているので載せる(別のテストで見る)
    { admission_year: '', faculty_name: '', department_name: '', file: nil }.each do |field, value|
      assert_no_difference('Curriculum.count', "#{field} が欠けていても作ってしまった") do
        post curricula_path, params: upload_params(field => value), env: ENV_LOCAL
      end
      expected = field == :file ? chosen : requirements_path
      assert_redirected_to expected, "#{field} が欠けたときの戻り先が違う"
    end
  end

  test 'curriculum がハッシュでなくても落ちず、何も作らない' do
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: { curriculum: 'x' }, env: ENV_LOCAL
    end
    assert_redirected_to requirements_path
    assert_predicate flash[:alert], :present?
  end

  test '同じ課程・同じ年度の公開済みがあっても、下書きを作れて、公開済みは変わらない' do
    published = Curriculum.published.find_by!(slug: 'intelligent_informatics', admission_year: 2025)
    before = published.attributes

    assert_difference('Curriculum.count', 1) do
      post curricula_path, params: upload_params(admission_year: published.admission_year), env: ENV_LOCAL
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
      assert_redirected_to requirements_path(faculty: '工学部', department: '工学科', course: '知能情報コース', admission_year: year)
    end
    [2000, upper].each do |year|
      assert_difference('Curriculum.count', 1, "#{year} を受けなかった") do
        post curricula_path, params: upload_params(admission_year: year), env: ENV_LOCAL
      end
    end
  end

  # ---- 識別名は人に入力させない。学部名・学科コース名から決める ----

  test '識別名を送らなくても、学部名と学科コース名から決まる' do
    post curricula_path, params: upload_params(admission_year: 2026), env: ENV_LOCAL

    assert_equal 'intelligent_informatics', Curriculum.order(:id).last.slug
  end

  test '新しい学部・コースには、新しい識別名が作られる' do
    post curricula_path, params: upload_params(faculty_name: '農学部', department_name: '亜熱帯農林環境科学科'), env: ENV_LOCAL

    created = Curriculum.order(:id).last
    assert_predicate created.slug, :present?
    assert_match Curriculum::SLUG_FORMAT, created.slug
    assert_not_equal 'intelligent_informatics', created.slug
  end

  test '識別名を送られても使わない(欄が無いので、古い画面や手書きの送信でも課程を取り違えない)' do
    post curricula_path, params: upload_params(slug: 'Bad Slug'), env: ENV_LOCAL

    assert_redirected_to curriculum_path(Curriculum.order(:id).last)
    assert_equal 'intelligent_informatics', Curriculum.order(:id).last.slug
  end

  # ---- 「その他（新しく登録する）」: 初めての学部・コースを登録する道は塞がない ----

  test 'その他を選んで打った学部名・学科コース名で、新しい課程の下書きを作れる' do
    post curricula_path, params: upload_params(faculty_name: CurriculaController::NEW_PROGRAM,
                                               faculty_name_other: '農学部',
                                               department_name: CurriculaController::NEW_PROGRAM,
                                               department_name_other: '亜熱帯農林環境科学科'), env: ENV_LOCAL

    created = Curriculum.order(:id).last
    assert_redirected_to curriculum_path(created)
    assert_equal %w[農学部 亜熱帯農林環境科学科], [created.faculty_name, created.department_name]
  end

  test '学部は既存で、学科コースだけその他を選んで新しく打てる' do
    post curricula_path, params: upload_params(department_name: CurriculaController::NEW_PROGRAM,
                                               department_name_other: '工学科 情報通信コース'), env: ENV_LOCAL

    created = Curriculum.order(:id).last
    assert_equal ['工学部', '工学科 情報通信コース'], [created.faculty_name, created.department_name]
    assert_not_equal 'intelligent_informatics', created.slug
  end

  test 'コースがある学科なのにコースを選ばずに送ると断る(department_nameが学科名だけにならない)' do
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: upload_params(department_name: '工学科', course_name: nil), env: ENV_LOCAL
    end

    assert_redirected_to requirements_path(faculty: '工学部', department: '工学科', admission_year: 2025)
    follow_redirect!
    assert_match(/コースを選んでください/, flash[:alert])
    assert_equal 0, Curriculum.where(department_name: '工学科').count
  end

  test 'その他を選んだのに何も打たなければ、作らずに学部名・学科コース名を求める' do
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: upload_params(faculty_name: CurriculaController::NEW_PROGRAM,
                                                 department_name: CurriculaController::NEW_PROGRAM,
                                                 faculty_name_other: ' ', department_name_other: ''), env: ENV_LOCAL
    end

    assert_redirected_to requirements_path
    assert_match(/学部名・学科・コース名/, flash[:alert])
  end

  test '選んだ名前の方が使われ、選ばなかった方に打ってあった名前は無視する' do
    post curricula_path, params: upload_params(faculty_name_other: '農学部', department_name_other: '別のコース'),
                         env: ENV_LOCAL

    created = Curriculum.order(:id).last
    assert_equal ['工学部', '工学科 知能情報コース'], [created.faculty_name, created.department_name]
  end

  test 'その他の自由入力に、選んだ印と同じ文字列を打っても、名前として保存しない' do
    # 全角スペースで囲んだ場合も弾く。日本語の画面では半角より打たれやすく、
    # squish を strip に変えると素通りして元の不具合に戻る
    sentinel = CurriculaController::NEW_PROGRAM
    [sentinel, " #{sentinel} ", "　#{sentinel}　"].each do |typed|
      assert_no_difference('Curriculum.count') do
        post curricula_path, params: upload_params(faculty_name: sentinel, faculty_name_other: typed,
                                                   department_name: sentinel,
                                                   department_name_other: typed), env: ENV_LOCAL
      end
      assert_redirected_to requirements_path
    end
  end

  test '選んだ印そのもの(その他)を学部名として保存しない' do
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: upload_params(faculty_name: CurriculaController::NEW_PROGRAM), env: ENV_LOCAL
    end
    assert_not Curriculum.exists?(faculty_name: CurriculaController::NEW_PROGRAM)
  end

  test 'PDFでないファイルは作らない' do
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: upload_params(file: text_upload('plain text')), env: ENV_LOCAL
    end
    assert_redirected_to requirements_path(faculty: '工学部', department: '工学科', course: '知能情報コース', admission_year: 2025)
    assert_match(/PDF/, flash[:alert])
  end

  # ---- 作れなかったときは、操作した人の選択を引き継いで戻す(選び直しも、畳まれた入口の探し直しもさせない) ----

  test '作れなかったときは、選んだ入学年度・学部・学科コースを載せた確認画面に戻す' do
    chosen = requirements_path(faculty: '工学部', department: '工学科', course: '知能情報コース', admission_year: 2027)
    refused = { 'PDFでない' => text_upload('plain text'),
                'PDFが無い' => nil,
                '大きすぎる' => text_upload("%PDF-1.4\n#{'a' * (CurriculaController::MAX_PDF_BYTES + 1)}") }

    refused.each do |reason, file|
      assert_no_difference('Curriculum.count', "#{reason}のに作ってしまった") do
        post curricula_path, params: upload_params(admission_year: 2027, file: file), env: ENV_LOCAL
      end
      assert_redirected_to chosen, "#{reason}とき、選択を載せずに戻した"
      assert_predicate flash[:alert], :present?
    end
  end

  test '作れなかったあとの画面は、選んだ組み合わせが4つのプルダウンで選ばれ、理由が出ている' do
    post curricula_path, params: upload_params(admission_year: 2025, file: text_upload('plain text')), env: ENV_LOCAL
    follow_redirect!

    assert_select '[role=alert]', text: /PDFファイルを選んでください/
    assert_select 'select#faculty option[selected][value=?]', '工学部'
    assert_select 'select#department option[selected][value=?]', '工学科'
    assert_select 'select#course option[selected][value=?]', '知能情報コース'
    assert_select 'select#admission_year option[selected][value=?]', '2025'
  end

  test '便覧がまだ無い組み合わせで作れなかったときは、取り込みのフォームが畳まれずに、選んだ値のまま出ている' do
    post curricula_path, params: upload_params(admission_year: 2027, file: text_upload('plain text')), env: ENV_LOCAL
    follow_redirect!

    assert_select '[role=alert]', text: /PDFファイルを選んでください/
    assert_select 'details[data-new-curriculum]', count: 0
    assert_select '[data-no-curriculum]', text: /2027年度入学/
    assert_select 'form[action=?] select#curriculum_admission_year option[selected][value=?]', curricula_path, '2027'
    assert_select 'form[action=?] select#curriculum_faculty_name option[selected][value=?]', curricula_path, '工学部'
  end

  test '「その他」で打った新しい学部名・学科コース名も、作れなかったときに引き継ぐ' do
    post curricula_path, params: upload_params(faculty_name: CurriculaController::NEW_PROGRAM,
                                               faculty_name_other: '農学部',
                                               department_name: CurriculaController::NEW_PROGRAM,
                                               department_name_other: '亜熱帯農林環境科学科', file: nil), env: ENV_LOCAL

    assert_redirected_to requirements_path(faculty: '農学部', department: '亜熱帯農林環境科学科', admission_year: 2025)
    follow_redirect!
    assert_select 'input#curriculum_faculty_name_other[value=?]', '農学部'
    assert_select 'input#curriculum_department_name_other[value=?]', '亜熱帯農林環境科学科'
  end

  test '大きすぎるPDFは作らない' do
    big = text_upload("%PDF-1.4\n#{'a' * (CurriculaController::MAX_PDF_BYTES + 1)}")
    assert_no_difference('Curriculum.count') do
      post curricula_path, params: upload_params(file: big), env: ENV_LOCAL
    end
    assert_match(/MB以下/, flash[:alert])
  end

  test 'ページ数を数えられなくても、失敗を記録して下書きは作る' do
    boom = ->(_path) { raise CurriculumImport::PageSource::PageCountError, 'Ghostscript(gs)が見つかりません。' }
    CurriculumImport::PageSource.stub(:page_count, boom) do
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
    refute_path_exists Curriculum.last.images_dir
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
    assert_redirected_to requirements_path_for(curriculum)
  end

  test '下書きを消したあとは、その下書きの組み合わせを選んだ確認画面に戻る。学部名が無い古い行は選択なしに戻る' do
    curriculum = draft
    delete curriculum_path(curriculum), env: ENV_LOCAL
    assert_redirected_to requirements_path(faculty: '工学部', department: '工学科', course: '知能情報コース', admission_year: 2025)

    legacy = Curriculum.create!(slug: 'legacy', admission_year: 2020, source_filename: 'l.pdf', pages: [])
    delete curriculum_path(legacy), env: ENV_LOCAL
    assert_redirected_to requirements_path
  end

  test '公開済みの便覧はこの画面から消せず、開けず、直せない' do
    published = Curriculum.published.first

    assert_no_difference('Curriculum.count') { delete curriculum_path(published), env: ENV_LOCAL }
    assert_redirected_to requirements_path_for(published)

    get curriculum_path(published), env: ENV_LOCAL
    assert_redirected_to requirements_path_for(published)

    before = published.reload.pages
    patch curriculum_path(published), params: { pages: { '1' => 'courses' } }, env: ENV_LOCAL
    assert_redirected_to requirements_path_for(published)
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

  test '確認画面は内部の識別名(slug)を見せない' do
    curriculum = draft
    curriculum.update!(slug: 'internal_key_abc')

    get curriculum_path(curriculum), env: ENV_LOCAL

    assert_response :success
    assert_select 'body', text: /識別名|internal_key_abc/, count: 0
    assert_select 'body', text: /handbook\.pdf/
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

  test '/requirements は、選ぶまで何も出さず、下書きは選んだ組み合わせから辿る。アップロードの入口もある' do
    mine = draft
    other = Curriculum.create!(slug: 'other', admission_year: 2026, faculty_name: '工学部', department_name: 'X',
                               source_filename: 'o.pdf', pages: blank_pages(2))

    get requirements_path, env: ENV_LOCAL

    assert_response :success
    assert_select 'section[data-group]', count: 0
    assert_select '[data-published-curricula], [data-draft-curricula]', count: 0
    # 下書きだけの年度・コースも、選択肢から選べる
    assert_select 'select[name=admission_year] option[value="2026"]'
    assert_select 'select[name=department] option[value=?]', 'X'

    get requirements_path(faculty: '工学部', department: '工学科', course: '知能情報コース', admission_year: 2025), env: ENV_LOCAL
    assert_select 'a[href=?]', curriculum_path(mine)
    assert_select 'a[href=?]', curriculum_path(other), count: 0

    get requirements_path(faculty: '工学部', department: 'X', admission_year: 2026), env: ENV_LOCAL
    assert_select 'a[href=?]', curriculum_path(other)
    assert_select 'a[href=?]', curriculum_path(mine), count: 0

    get requirements_path(faculty: '工学部', department: 'X', admission_year: 2030), env: ENV_LOCAL
    assert_select 'form[action=?][enctype="multipart/form-data"]', curricula_path do
      assert_select 'input[name="curriculum[slug]"]', count: 0
      assert_select 'select[name="curriculum[admission_year]"]'
      assert_select 'select[name="curriculum[faculty_name]"]'
      assert_select 'select[name="curriculum[department_name]"]'
      assert_select 'input[type=file][name="curriculum[file]"][accept="application/pdf"]'
    end
  end

  # ---- 取り込みフォーム: 識別名の欄は無く、3つの欄はプルダウン ----

  def this_year = Time.zone.today.year

  test 'フォームに識別名の入力欄は無い' do
    get requirements_path, env: ENV_LOCAL

    assert_select 'input[name=?]', 'curriculum[slug]', count: 0
    assert_select 'select[name=?]', 'curriculum[admission_year]'
    assert_select 'body', text: /識別名|slug/, count: 0
  end

  test '入学年度は、今年の10年前から再来年までのプルダウン(新しい順)で、今年が選ばれている' do
    get requirements_path, env: ENV_LOCAL

    options = css_select("select[name='curriculum[admission_year]'] option")
    assert_equal ((this_year - 10)..(this_year + 2)).to_a.reverse.map(&:to_s), options.pluck('value')
    assert_equal [this_year.to_s], options.select { |option| option['selected'] }.pluck('value')
    # 検証が受ける範囲の中だけ(選べるのに、送ったら断られる年度を出さない)
    assert(options.all? { |option| Curriculum.upload_year_range.cover?(option['value'].to_i) })
  end

  test '学部名・学科名・コース名は、Faculty/Department/Programから作ったプルダウンで、最後に「その他」がある' do
    get requirements_path, env: ENV_LOCAL

    faculty = css_select("select[name='curriculum[faculty_name]'] option").pluck('value')
    assert_equal ['', '工学部', CurriculaController::NEW_PROGRAM], faculty
    assert_select "select[name='curriculum[faculty_name]'] option[value=?]", CurriculaController::NEW_PROGRAM,
                  text: 'その他（新しく登録する）'
    assert_select "select[name='curriculum[department_name]'] optgroup[label=?] option[value=?]", '工学部', '工学科'
    assert_select "select[name='curriculum[department_name]'] option[value=?]", CurriculaController::NEW_PROGRAM,
                  text: 'その他（新しく登録する）'
    assert_select "select[name='curriculum[course_name]'] optgroup[label=?] option[value=?]", '工学科', '知能情報コース'
    assert_select "select[name='curriculum[course_name]'] option[value=?]", CurriculaController::NEW_PROGRAM,
                  text: 'その他（新しく登録する）'
  end

  test 'その他の自由入力欄は、その他を選ぶまでは隠れていて、隠れている間は入力を求めない' do
    get requirements_path, env: ENV_LOCAL

    assert_select '[data-new-faculty][hidden] input[name=?]:not([required])', 'curriculum[faculty_name_other]'
    assert_select '[data-new-department][hidden] input[name=?]:not([required])', 'curriculum[department_name_other]'
    assert_select '[data-new-course][hidden] input[name=?]:not([required])', 'curriculum[course_name_other]'
  end

  test '選んだ組み合わせに便覧が無いときは、その学部・学科・コース・年度をフォームに入れておく' do
    get requirements_path(faculty: '工学部', department: '工学科', course: '知能情報コース',
                          admission_year: this_year + 1), env: ENV_LOCAL

    assert_select "select[name='curriculum[faculty_name]'] option[selected][value=?]", '工学部'
    assert_select "select[name='curriculum[department_name]'] option[selected][value=?]", '工学科'
    assert_select "select[name='curriculum[course_name]'] option[selected][value=?]", '知能情報コース'
    assert_select "select[name='curriculum[admission_year]'] option[selected][value=?]", (this_year + 1).to_s
    assert_select '[data-new-faculty][hidden]'
    assert_select '[data-new-department][hidden]'
    assert_select '[data-new-course][hidden]'
  end

  test '選んだ学部・学科が選択肢に無いときは、その他を選び、選んだ名前を自由入力欄に入れておく' do
    get requirements_path(faculty: '農学部', department: '亜熱帯農林環境科学科', admission_year: this_year + 1), env: ENV_LOCAL

    assert_select "select[name='curriculum[faculty_name]'] option[selected][value=?]", CurriculaController::NEW_PROGRAM
    assert_select "select[name='curriculum[department_name]'] option[selected][value=?]", CurriculaController::NEW_PROGRAM
    assert_select '[data-new-faculty]:not([hidden]) input[name=?][value=?][required]',
                  'curriculum[faculty_name_other]', '農学部'
    assert_select '[data-new-department]:not([hidden]) input[name=?][value=?][required]',
                  'curriculum[department_name_other]', '亜熱帯農林環境科学科'
  end

  test '学部・学科は選択肢にあって、コースだけ無いときは、コースだけ自由入力にする' do
    get requirements_path(faculty: '工学部', department: '工学科', course: '情報通信コース',
                          admission_year: this_year + 1), env: ENV_LOCAL

    assert_select "select[name='curriculum[faculty_name]'] option[selected][value=?]", '工学部'
    assert_select "select[name='curriculum[department_name]'] option[selected][value=?]", '工学科'
    assert_select "select[name='curriculum[course_name]'] option[selected][value=?]", CurriculaController::NEW_PROGRAM
    assert_select '[data-new-faculty][hidden]'
    assert_select '[data-new-department][hidden]'
    assert_select '[data-new-course]:not([hidden]) input[name=?][value=?]', 'curriculum[course_name_other]',
                  '情報通信コース'
  end

  test '選んだ年度が今年の10年前より古くても、検証が受ける範囲なら、その年度を選択肢に足す' do
    get requirements_path(faculty: '工学部', department: '工学科', course: '知能情報コース', admission_year: 2003), env: ENV_LOCAL
    assert_select "select[name='curriculum[admission_year]'] option[selected][value=?]", '2003'

    # 検証が断る年度は足さない(選べるのに送ると断られる選択肢にしない)
    get requirements_path(faculty: '工学部', department: '工学科', course: '知能情報コース', admission_year: 1990), env: ENV_LOCAL
    assert_select "select[name='curriculum[admission_year]'] option[value=?]", '1990', count: 0
    assert_select "select[name='curriculum[admission_year]'] option[selected][value=?]", this_year.to_s
  end

  test '選んだ値に変な文字が入っていても、フォームに入れるときにエスケープする' do
    get requirements_path(faculty: '<script>alert(1)</script>', department: '"><img src=x>', admission_year: this_year),
        env: ENV_LOCAL

    assert_response :success
    assert_select 'script', text: /alert\(1\)/, count: 0
    assert_select 'img[src=x]', count: 0
  end

  test 'ページ数を数えられなかった下書きは、続きのリンクの横で要確認と分かる' do
    ok = draft
    failed = draft(pages: [])
    failed.update!(import_error: 'Ghostscript(gs)が見つかりません。')

    get requirements_path(faculty: '工学部', department: '工学科', course: '知能情報コース', admission_year: 2025), env: ENV_LOCAL

    assert_select 'li', text: /下書き/, minimum: 2
    assert_select %(li:has(a[href="#{curriculum_path(failed)}"])), text: /要確認/
    assert_select %(li:has(a[href="#{curriculum_path(ok)}"])), text: /要確認/, count: 0
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

