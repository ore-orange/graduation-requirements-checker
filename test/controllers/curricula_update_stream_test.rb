# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require_relative '../support/requirements_draft_fixtures'

# ページの指定の保存を、Turbo Stream でも受ける。「この指定で読み取る」が、保存を fetch で送ってそのまま読み取りに入るため。
# 警告(読み取り結果を外す・人が直したものがあるページを読み直す)は、保存の応答に載せて返す。JavaScript が動かないときの
# 「ページの指定を保存」は、いまどおり画面を開き直す(HTML の経路)。
class CurriculaUpdateStreamTest < ActionDispatch::IntegrationTest
  include RequirementsDraftFixtures
  include RequirementsScreenHelpers

  STREAM = { 'Accept' => 'text/vnd.turbo-stream.html' }.freeze

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
  end

  teardown do
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
  end

  def save_pages(draft, pages, headers: STREAM, **extra)
    CurriculumReader.stub(:available?, true) do
      patch curriculum_path(draft), params: { pages: pages, **extra }, headers: headers, env: ENV_LOCAL
    end
  end

  # 応答の保存結果の要素が持つ警告(JSON の配列)
  def warnings
    element = css_select('#pages-save-result').first
    JSON.parse(element['data-save-warnings'])
  end

  test 'Turbo Stream で指定を保存でき、ページの行が差し替わる' do
    draft = draft()

    save_pages(draft, { '1' => 'courses' })

    assert_response :success
    assert_equal 'text/vnd.turbo-stream.html', response.media_type
    assert_equal %w[courses requirements], draft.reload.pages.pluck('kind')
    assert_select 'turbo-stream[action=replace][target=?]', "page_1_curriculum_#{draft.id}"
    assert_select 'turbo-stream[action=replace][target=?]', "page_2_curriculum_#{draft.id}"
    # 新しく読む種別になったページは、読み取りの宛先を持つ(これが無いと、保存の直後に読み取りへ進めない)
    row = "li#page_1_curriculum_#{draft.id}[data-kind=courses]"
    assert_select "#{row}[data-read-url=?]", read_page_curriculum_path(draft, page: 1)
  end

  test '種別を替えて結果を外したとき、警告が応答に入る' do
    draft = draft()

    save_pages(draft, { '2' => 'skip' })

    assert_response :success
    assert_equal 1, warnings.size
    assert_match(/2ページの読み取り結果は外しました/, warnings.first)
  end

  test '人が直した規則があるページを読み直すとき、警告が応答に入る' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: '5' }]
    draft.update!(pages: draft.reload.pages.map { |page| page['page'] == 2 ? page.merge('status' => 'failed') : page })

    save_pages(draft, { '2' => 'requirements' })

    assert_response :success
    assert_equal 1, warnings.size
    assert_match(/2ページを読み直します/, warnings.first)
    assert_match(/規則: 規則humanities\(humanities\)/, warnings.first)
  end

  test '読み終わっているページは読み直さないので、人が直したものがあっても警告に入れない' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: '5' }]

    save_pages(draft, { '2' => 'requirements' })

    assert_equal [], warnings
  end

  test '行の「読む」(only_page)は、読み終わっているそのページの読み直しの警告も返し、他のページの警告は返さない' do
    draft = draft()
    save draft, rules: [{ id: 'humanities', required_credits: '5' }]

    save_pages(draft, { '2' => 'requirements' }, only_page: '2')
    assert_match(/2ページを読み直します/, warnings.first)

    save_pages(draft, { '2' => 'requirements' }, only_page: '1')
    assert_equal [], warnings
  end

  test '警告が無いときは、警告の欄が空で返る' do
    draft = draft()

    save_pages(draft, { '1' => 'courses' })

    assert_response :success
    assert_equal [], warnings
  end

  test '保存できないときは、理由を返し、行は差し替えず、何も変えない' do
    draft = draft()

    save_pages(draft, { '1' => 'bogus' })

    assert_response :unprocessable_content
    assert_equal 'text/vnd.turbo-stream.html', response.media_type
    assert_select 'turbo-stream[action=replace][target=pages-save-result]'
    assert_select '#pages-save-result [role=alert]', text: /いずれかを、存在するページに指定してください/
    assert_select 'turbo-stream[target=?]', "page_1_curriculum_#{draft.id}", count: 0
    assert_equal %w[skip requirements], draft.reload.pages.pluck('kind')
  end

  test '公開済みの便覧は、Turbo Stream でも保存できない(画面の開き直しへ誘導し、指定は変えない)' do
    published = draft
    published.update!(published_at: Time.current)

    save_pages(published, { '1' => 'courses' })

    assert_response :see_other
    assert_equal %w[skip requirements], published.reload.pages.pluck('kind')
  end

  test 'HTML の送信は、いまどおり画面を開き直す' do
    draft = draft()

    save_pages(draft, { '1' => 'courses' }, headers: {})

    assert_redirected_to curriculum_path(draft)
    assert_equal 'ページの指定を保存しました。', flash[:notice]
    assert_equal %w[courses requirements], draft.reload.pages.pluck('kind')
  end

  test '読み取りの画面には、読み取りの結果を入れる欄と進み具合の表示がある' do
    draft = draft()
    CurriculumReader.stub(:available?, true) { show(draft) }

    assert_select '#pages-save-result[data-save-warnings=?]', '[]'
    assert_select 'progress[data-read-pages-target=bar]'
    assert_select "button[data-page-wizard-target=commit][data-action*='read-pages#saveAndRead']:not([disabled])"
  end

  test 'APIキーが無いときは、読み取る押しボタンを使えないままにする' do
    draft = draft()
    CurriculumReader.stub(:available?, false) { show(draft) }

    assert_select 'button[data-page-wizard-target=commit][disabled]'
  end
end

