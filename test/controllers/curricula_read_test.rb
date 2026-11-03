# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

# 便覧の下書きを1ページずつ読む。読み取りの窓口は代役に差し替え、実際の外部APIは呼ばない。
class CurriculaReadTest < ActionDispatch::IntegrationTest
  ENV_LOCAL = { 'REMOTE_ADDR' => '127.0.0.1' }.freeze
  STREAM = { 'Accept' => 'text/vnd.turbo-stream.html' }.freeze

  class StubReader
    def initialize(requirements: nil, courses: nil, error: nil)
      @requirements = requirements
      @courses = courses
      @error = error
    end

    def read_requirements(**)
      raise @error if @error

      @requirements
    end

    def read_courses(**)
      raise @error if @error

      @courses
    end
  end

  REQUIREMENTS = {
    'categories' => [{ 'key' => 'course_required', 'label' => 'コース専門必修', 'counts_toward_total' => true }],
    'roles' => [],
    'rules' => [{ 'id' => 'common_total', 'type' => 'credit_sum', 'label' => '共通教育',
                  'categories' => ['course_required'], 'required_credits' => 30 }],
    'display' => { 'groups' => [] }
  }.freeze
  COURSES = { 'courses' => [{ 'number' => '知能101', 'name' => 'プログラミング演習Ⅰ', 'credits' => 1,
                              'category' => 'course_required', 'required' => true, 'requires_approval' => false,
                              'language' => nil, 'review_reason' => nil, 'roles' => [] }] }.freeze

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
    pages = [[1, 'skip'], [2, 'requirements'], [3, 'courses']].map do |number, kind|
      { 'page' => number, 'kind' => kind, 'status' => 'pending', 'error' => nil, 'text' => "p#{number}" }
    end
    @draft = Curriculum.create!(slug: 'x', admission_year: 2025, faculty_name: '工学部', department_name: '工学科 知能情報コース',
                                source_filename: 'handbook.pdf', pages: pages)
    FileUtils.mkdir_p(@draft.images_dir)
    [2, 3].each { |page| File.binwrite(@draft.images_dir.join("p#{page}.png"), "\x89PNG".b) }
  end

  teardown do
    FileUtils.rm_rf(@draft.images_dir)
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
  end

  def read_page(page, reader, headers: STREAM)
    CurriculumReader.stub(:available?, true) do
      CurriculumReader.stub(:new, reader) do
        post read_page_curriculum_path(@draft, page: page), headers: headers, env: ENV_LOCAL
      end
    end
  end

  def page_entry(number) = @draft.reload.pages.find { |page| page['page'] == number }

  test 'APIキーがなければ読み取りボタンを出さず、ページの指定は今までどおり使える' do
    CurriculumReader.stub(:available?, false) do
      get curriculum_path(@draft), env: ENV_LOCAL
      assert_response :success
      assert_select 'button', text: '全部読む', count: 0
      assert_select 'button', text: '読む', count: 0
      assert_select 'form[action=?]', curriculum_path(@draft)
      assert_select 'input[type=radio]', count: 9
      assert_select 'li[data-read-url]', count: 0
      assert_match(/APIキー/, response.body)
    end
  end

  test 'APIキーがあれば全部読むボタンと、読むページの行に読み取りの宛先が出る' do
    CurriculumReader.stub(:available?, true) do
      get curriculum_path(@draft), env: ENV_LOCAL

      assert_select 'button', text: '全部読む', count: 1
      assert_select 'li[data-read-url]', count: 2
      assert_select 'li[data-page="1"][data-read-url]', count: 0, message: '読まないページは読み取れない'
      assert_select 'li[data-page="2"][data-read-url=?]', read_page_curriculum_path(@draft, page: 2)
    end
  end

  test '読めるページが1つもなければ全部読むボタンは出さない' do
    @draft.update!(pages: @draft.pages.map { |page| page.merge('kind' => 'skip') })
    CurriculumReader.stub(:available?, true) do
      get curriculum_path(@draft), env: ENV_LOCAL
      assert_select 'button', text: '全部読む', count: 0
    end
  end

  test '1ページ読むと、そのページの行だけを Turbo Stream で差し替える' do
    read_page(2, StubReader.new(requirements: REQUIREMENTS))

    assert_response :success
    assert_equal 'text/vnd.turbo-stream.html', response.media_type
    assert_select 'turbo-stream[action=replace][target=?]', ActionView::RecordIdentifier.dom_id(@draft, 'page_2')
    assert_select 'turbo-stream', count: 1
    assert_match(/読み取り済み/, response.body)
    assert_equal 'read', page_entry(2)['status']
    assert_equal %w[common_total], @draft.reload.document['rules'].pluck('id')
  end

  test '科目表のページを読むと科目が入る' do
    read_page(2, StubReader.new(requirements: REQUIREMENTS))
    read_page(3, StubReader.new(courses: COURSES))

    assert_response :success
    assert_equal %w[知能101], @draft.reload.document['courses'].pluck('number')
  end

  test '読み取りが落ちたら、そのページの行に失敗の理由を出し、ステータスは 422、ほかのページは変わらない' do
    read_page(2, StubReader.new(requirements: REQUIREMENTS))
    read_page(3, StubReader.new(error: CurriculumReader::Error.new('読み取りを呼び出せませんでした(HTTP 429、3回試しました)。')))

    assert_response :unprocessable_content
    assert_equal 'text/vnd.turbo-stream.html', response.media_type
    assert_match(/HTTP 429/, response.body)
    assert_equal 'failed', page_entry(3)['status']
    assert_equal 'read', page_entry(2)['status']
  end

  test '要件表より先に科目表を読もうとしても、500にせず、そのページだけ failed にする' do
    read_page(3, StubReader.new(courses: COURSES))

    assert_response :unprocessable_content
    assert_match(/要件表/, response.body)
    assert_equal 'failed', page_entry(3)['status']
    assert_equal 'pending', page_entry(2)['status']
  end

  test '読まないページは読み取りを呼ばず、状態も変えない' do
    reader = Minitest::Mock.new
    read_page(1, reader)

    assert_equal 'pending', page_entry(1)['status']
    assert_equal({}, @draft.reload.document)
  end

  test '存在しないページは404' do
    read_page(99, StubReader.new)
    assert_response :not_found
  end

  test 'ページ番号が数字でなければ404' do
    read_page('abc', StubReader.new)
    assert_response :not_found
  end

  test 'APIキーが無ければ読み取りを呼ばず、状態も変えない' do
    CurriculumReader.stub(:available?, false) do
      CurriculumReader.stub(:new, ->(*) { flunk 'キーが無いのに窓口を作った' }) do
        post read_page_curriculum_path(@draft, page: 2), headers: STREAM, env: ENV_LOCAL
      end
    end

    assert_response :service_unavailable
    assert_equal 'pending', page_entry(2)['status']
  end

  test 'Turbo Stream を受け付けないリクエストは、確認画面へ戻す' do
    read_page(2, StubReader.new(requirements: REQUIREMENTS), headers: {})

    assert_redirected_to curriculum_path(@draft)
    assert_equal 'read', page_entry(2)['status']
  end

  test '公開済みの便覧は読み取れない' do
    published = Curriculum.published.first
    CurriculumReader.stub(:available?, true) do
      post read_page_curriculum_path(published, page: 1), headers: STREAM, env: ENV_LOCAL
    end

    assert_redirected_to requirements_path_for(published)
  end

  test '読み取りが終わる前に読み込んだ手元の pages で種別を保存しても、読み終わったページは未読に戻らない' do
    stale = Curriculum.find(@draft.id)
    read_page(2, StubReader.new(requirements: REQUIREMENTS))
    assert_equal 'read', page_entry(2)['status']

    # 保存の要求が、読み取りの完了より前に行を読み込んでいた状況
    Curriculum.stub(:find, stale) do
      patch curriculum_path(@draft), params: { pages: { '3' => 'skip' } }, env: ENV_LOCAL
    end

    assert_redirected_to curriculum_path(@draft)
    assert_equal 'read', page_entry(2)['status']
    assert_predicate page_entry(2)['contributed'], :present?
    assert_equal 'skip', page_entry(3)['kind']
  end

  test '読み取り済みのページの種別を替えて保存すると、結果を外したページを知らせる' do
    read_page(2, StubReader.new(requirements: REQUIREMENTS))

    patch curriculum_path(@draft), params: { pages: { '2' => 'skip', '3' => 'courses' } }, env: ENV_LOCAL

    assert_redirected_to curriculum_path(@draft)
    assert_match(/2ページの読み取り結果は外しました/, flash[:notice])
    assert_equal 'pending', page_entry(2)['status']
  end

  test '読めたあとの読み直しが失敗したページも、種別を替えて結果を外すときは知らせる' do
    read_page(2, StubReader.new(requirements: REQUIREMENTS))
    read_page(2, StubReader.new(error: CurriculumReader::Error.new('429')))
    assert_equal 'failed', page_entry(2)['status']
    assert_equal %w[common_total], @draft.reload.document['rules'].pluck('id')

    patch curriculum_path(@draft), params: { pages: { '2' => 'skip' } }, env: ENV_LOCAL

    assert_match(/2ページの読み取り結果は外しました/, flash[:notice])
    assert_empty @draft.reload.document['rules']
  end

  test '読み取り済みのページの種別を替えなければ、外したという知らせは出ない' do
    read_page(2, StubReader.new(requirements: REQUIREMENTS))

    patch curriculum_path(@draft), params: { pages: { '2' => 'requirements', '3' => 'skip' } }, env: ENV_LOCAL

    assert_equal 'ページの指定を保存しました。', flash[:notice]
    assert_equal 'read', page_entry(2)['status']
  end

  test 'ローカル以外からは読み取れない' do
    CurriculumReader.stub(:available?, true) do
      post read_page_curriculum_path(@draft, page: 2), headers: STREAM, env: { 'REMOTE_ADDR' => '203.0.113.9' }
    end

    assert_response :not_found
    assert_equal 'pending', page_entry(2)['status']
  end
end

