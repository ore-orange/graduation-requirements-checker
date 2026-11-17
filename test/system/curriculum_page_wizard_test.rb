# frozen_string_literal: true

require 'application_system_test_case'
require 'minitest/mock'

# 便覧の下書きの手順①。読むページを、1ページずつ見て 読まない・要件表・科目表 から選び、最後に一覧で確認する。
# 1枚表示にするのは Stimulus なので、HTML だけを見るコントローラのテストでは確かめられない。ここで実ブラウザで確かめる。
# (bin/ci は system テストを走らせない。bin/rails test:system test/system/curriculum_page_wizard_test.rb で自分で走らせる)
class CurriculumPageWizardTest < ApplicationSystemTestCase
  # 1x1 の PNG。画像として読めさえすればよい。
  PNG = Base64.decode64(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
  )

  setup do
    pages = Curriculum.blank_pages(5, texts: ['', '', '', '', 'あ' * 300])
    @curriculum = Curriculum.create!(slug: 'x', admission_year: 2025, faculty_name: '工学部',
                                     department_name: '工学科 知能情報コース', source_filename: 'handbook.pdf', pages: pages)
    FileUtils.mkdir_p(@curriculum.images_dir)
    (1..4).each { |number| File.binwrite(@curriculum.images_dir.join("p#{number}.png"), PNG) } # 5ページ目だけ画像が無い
    visit curriculum_path(@curriculum)
  end

  teardown { FileUtils.rm_rf(@curriculum.images_dir) }

  def checked_kind(number) = find("input[name='pages[#{number}]']:checked", visible: :all).value

  test '最初は1ページ目だけが1枚表示で出る' do
    assert_text '1ページ目 / 全5ページ'
    assert_selector "#page_1_curriculum_#{@curriculum.id} img[width='600']"
    assert_selector "li[data-page-wizard-target='page']", count: 1
    assert_text '指定済み 0 / 5'
    assert_no_text '指定の確認'
  end

  test '種別を選ぶと次のページへ進む' do
    choose '要件表'

    assert_text '2ページ目 / 全5ページ'
    assert_text '指定済み 1 / 5'
    choose '読まない' # すでに「読まない」が選ばれているページでも、押せば進む

    assert_text '3ページ目 / 全5ページ'
    assert_text '指定済み 2 / 5'
    assert_equal 'requirements', checked_kind(1) # 選んだ結果は、進んだあとも残る
  end

  test '前へ・次へでページを行き来できる' do
    click_on '次へ'
    click_on '次へ'
    assert_text '3ページ目 / 全5ページ'

    click_on '前へ'
    assert_text '2ページ目 / 全5ページ'
    click_on '前へ'
    assert_text '1ページ目 / 全5ページ'
    assert_button '前へ', disabled: true # 1ページ目より前へは行かない
  end

  test '最後のページの次で、一覧が出る' do
    4.times { click_on '次へ' }
    assert_text '5ページ目 / 全5ページ'
    click_on '次へ'

    assert_text '指定の確認'
    assert_selector "li[data-page-wizard-target='page']", count: 5
    assert_no_text '5ページ目 / 全5ページ'
  end

  test '一覧の「直す」で、そのページの1枚表示に戻る' do
    click_on '全ページを一覧で見る'
    assert_selector "li[data-page-wizard-target='page']", count: 5

    within("#page_3_curriculum_#{@curriculum.id}") { click_on '直す' }

    assert_text '3ページ目 / 全5ページ'
    assert_selector "li[data-page-wizard-target='page']", count: 1
    assert_no_text '指定の確認'
  end

  test '一覧に、要件表・科目表・読まないの件数が出る' do
    CurriculumReader.stub(:available?, true) { visit curriculum_path(@curriculum) }
    choose '要件表'
    choose '科目表'
    choose '科目表'
    choose '読まない'
    choose '要件表' # 5ページ目の次で、一覧になる

    assert_text '指定の確認'
    assert_text '要件表 2 ・ 科目表 2 ・ 読まない 1'
    # 読み取りの窓口が使えるときは押せる。使えないとき(APIキーが無い)は押せないまま。
    assert_button 'この指定で読み取る(4ページ)', disabled: false
    within("#page_2_curriculum_#{@curriculum.id}") { assert_text '科目表' }
  end

  test '読み取りの窓口が使えないときは、「この指定で読み取る」を押せないままにする' do
    CurriculumReader.stub(:available?, false) do
      visit curriculum_path(@curriculum)
      click_on '全ページを一覧で見る'

      assert_button 'この指定で読み取る(0ページ)', disabled: true
    end
  end

  test '画像が無いページでは、取り出した文字の冒頭が出る' do
    4.times { click_on '次へ' }

    assert_text '5ページ目 / 全5ページ'
    assert_text 'あ' * 200
    assert_no_selector 'img', visible: :visible
  end

  test 'キーボードの左右で前後し、1・2・3 で種別を選んで進む' do
    find('body').send_keys(:right)
    assert_text '2ページ目 / 全5ページ'
    find('body').send_keys(:left)
    assert_text '1ページ目 / 全5ページ'

    find('body').send_keys('2') # 要件表
    assert_text '2ページ目 / 全5ページ'
    find('body').send_keys('3') # 科目表
    assert_text '3ページ目 / 全5ページ'
    find('body').send_keys('1') # 読まない

    assert_text '4ページ目 / 全5ページ'
    assert_equal 'requirements', checked_kind(1)
    assert_equal 'courses', checked_kind(2)
    assert_equal 'skip', checked_kind(3)
  end

  # ---- 「この指定で読み取る」: 保存から読み取りまで1回の操作で進み、進み具合を見せる ----
  # 読み取りの窓口は代役に差し替える(外部APIは呼ばない)。画面のサーバーは同じプロセスなので、差し替えはそのまま効く。

  REQUIREMENTS = {
    'categories' => [{ 'key' => 'course_required', 'label' => 'コース専門必修', 'counts_toward_total' => true }],
    'roles' => [],
    'rules' => [{ 'id' => 'common_total', 'type' => 'credit_sum', 'label' => '共通教育のしばり',
                  'categories' => ['course_required'], 'required_credits' => 30 }],
    'display' => { 'groups' => [] }
  }.freeze
  COURSES = { 'courses' => [{ 'number' => '知能101', 'name' => 'プログラミング演習Ⅰ', 'credits' => 1,
                              'category' => 'course_required', 'required' => true, 'requires_approval' => false,
                              'language' => nil, 'review_reason' => nil, 'roles' => [] }] }.freeze

  # 呼ばれたページを覚え、delay 秒かけて答える窓口の代役。fail_on のページ画像のときだけ読み取りに失敗する。
  class StubReader
    attr_reader :calls, :kinds

    def initialize(delay: 0, fail_on: nil)
      @kinds = []
      @delay = delay
      @fail_on = fail_on
      @calls = []
    end

    def read_requirements(image_path:, **)
      @kinds << :requirements
      answer(image_path, REQUIREMENTS)
    end

    def read_courses(image_path:, **)
      @kinds << :courses
      answer(image_path, COURSES)
    end

    private

    def answer(image_path, result)
      @calls << File.basename(image_path.to_s)
      sleep @delay
      raise CurriculumReader::Error, 'テスト用の失敗です。' if @fail_on && File.basename(image_path.to_s) == @fail_on

      result
    end
  end

  def with_reader(reader, &)
    CurriculumReader.stub(:available?, true) do
      CurriculumReader.stub(:new, reader, &)
    end
  end

  # 1ページ目から順に種別を選び、最後の次で出る一覧まで進む。
  def specify(*labels)
    labels.each { |label| choose label }
    assert_text '指定の確認'
  end

  def statuses = @curriculum.reload.pages.pluck('status')

  def kinds = @curriculum.reload.pages.pluck('kind')

  test '「この指定で読み取る」で、保存から読み取りまで1回の操作で進む' do
    reader = StubReader.new
    with_reader(reader) do
      visit curriculum_path(@curriculum)
      specify '要件表', '科目表', '読まない', '読まない', '読まない'
      click_on 'この指定で読み取る(2ページ)'

      assert_text '読み取りが終わりました。'
    end

    assert_equal %w[requirements courses skip skip skip], kinds # 「ページの指定を保存」を押していないのに保存されている
    assert_equal %w[read read pending pending pending], statuses
    assert_equal %w[p1.png p2.png], reader.calls # 要件表を先に読む
    assert_selector "#page_1_curriculum_#{@curriculum.id}", text: '読み取り済み'
  end

  test '警告があるときは、確認してから読み取りに入る' do
    hold_a_result_on_first_page
    reader = StubReader.new
    with_reader(reader) do
      visit curriculum_path(@curriculum)
      specify '読まない', '要件表', '読まない', '読まない', '読まない' # 1ページ目の結果を持つ種別を替える
      message = accept_confirm { click_on 'この指定で読み取る(1ページ)' }

      assert_match(/1ページの読み取り結果は外しました/, message)
      assert_text '読み取りが終わりました。'
    end

    assert_equal %w[p2.png], reader.calls
  end

  test '警告の確認を断ると、保存はするが読み取りには入らない' do
    hold_a_result_on_first_page
    reader = StubReader.new
    with_reader(reader) do
      visit curriculum_path(@curriculum)
      specify '読まない', '要件表', '読まない', '読まない', '読まない'
      dismiss_confirm { click_on 'この指定で読み取る(1ページ)' }

      assert_text '読み取りは始めませんでした'
      assert_button 'この指定で読み取る(1ページ)', disabled: false # 押し直せる
    end

    assert_empty reader.calls
    assert_equal %w[skip requirements skip skip skip], kinds
    assert_equal %w[pending pending pending pending pending], statuses
  end

  test '読み取り中に、進み具合のバーと n / m ページと、経過秒数が出る' do
    reader = StubReader.new(delay: 2.5)
    with_reader(reader) do
      visit curriculum_path(@curriculum)
      specify '要件表', '科目表', '読まない', '読まない', '読まない'
      click_on 'この指定で読み取る(2ページ)'

      assert_selector 'progress[max="2"][value="0"]'
      assert_text '0 / 2 ページ'
      assert_text '1ページを読み取っています…(0:00)'
      assert_text '1ページを読み取っています…(0:01)' # 秒数が動いている(止まって見えない)
      assert_text '1 / 2 ページ'
      assert_selector 'progress[value="1"]'
      assert_text '読み取りが終わりました。', wait: 10
      assert_selector 'progress[value="2"]'
    end
  end

  test '読み取り中は、②③④の節を触れず、終わると触れる' do
    with_reader(StubReader.new(delay: 2)) do
      visit curriculum_path(@curriculum)
      specify '要件表', '読まない', '読まない', '読まない', '読まない'
      click_on 'この指定で読み取る(1ページ)'

      %w[requirements_review course-review publish].each do |id|
        assert_selector "##{id}[inert]"
        assert_selector "##{id} [data-reading-note]", text: '読み取りが終わると出ます'
      end
      assert_text '読み取りが終わりました。', wait: 10
      %w[requirements_review course-review publish].each do |id|
        assert_no_selector "##{id}[inert]"
        assert_no_selector "##{id} [data-reading-note]"
      end
    end
  end

  test '読み取りが終わると、②へ進むボタンが出て、押すと読み取った結果が下に出る' do
    with_reader(StubReader.new) do
      visit curriculum_path(@curriculum)
      assert_no_text '共通教育のしばり'
      specify '要件表', '読まない', '読まない', '読まない', '読まない'
      assert_no_button '要件表の確認へ'
      click_on 'この指定で読み取る(1ページ)'

      assert_text '読み取りが終わりました。'
      click_on '要件表の確認へ'

      within('#requirements_review') { assert_text '共通教育のしばり' } # 開き直したので、読み取った規則が出る
      assert_equal 'requirements_review', page.evaluate_script('location.hash').delete('#')
    end
  end

  test '1ページ失敗しても、残りのページを読み続ける' do
    reader = StubReader.new(fail_on: 'p2.png')
    with_reader(reader) do
      visit curriculum_path(@curriculum)
      specify '要件表', '科目表', '科目表', '読まない', '読まない'
      click_on 'この指定で読み取る(3ページ)'

      assert_text '1ページは読めませんでした'
    end

    assert_equal %w[p1.png p2.png p3.png], reader.calls
    assert_equal %w[read failed read pending pending], statuses
    assert_button '要件表の確認へ' # 1ページでも読めていれば、結果を見に行ける
  end

  test '読まないページしか無いときは、読み取りに入らず理由を出す' do
    reader = StubReader.new
    with_reader(reader) do
      visit curriculum_path(@curriculum)
      click_on '全ページを一覧で見る'
      click_on 'この指定で読み取る(0ページ)'

      assert_text '読み取るページ(要件表・科目表)が選ばれていないので、読み取りは始めませんでした'
      assert_no_selector 'progress', visible: :visible
      assert_no_selector '[inert]'
    end

    assert_empty reader.calls
  end

  test '「全部読む」も、保存してから読む(未保存の選択が、読み取りで保存値に戻らない)' do
    first_page_is_requirements
    reader = StubReader.new
    with_reader(reader) do
      visit curriculum_path(@curriculum)
      specify '要件表', '科目表', '読まない', '読まない', '読まない' # 2ページ目の科目表は、まだ保存していない選択
      click_on '全部読む'

      assert_text '読み取りが終わりました。'
    end

    assert_equal %w[requirements courses skip skip skip], kinds
    assert_equal %w[read read pending pending pending], statuses
    assert_equal %w[p1.png p2.png], reader.calls
  end

  test '行の「読む」も、保存してから読む(種別を変えて保存せずに押すと、変えたあとの種別で読まれる)' do
    # 1ページ目を要件表で読んでおき、要件表(区分)がある状態にする
    first_page_is_requirements
    reader = StubReader.new
    with_reader(reader) do
      visit curriculum_path(@curriculum)
      specify '要件表', '読まない', '読まない', '読まない', '読まない'
      click_on 'この指定で読み取る(1ページ)'
      assert_text '読み取りが終わりました。'
      reader.kinds.clear
      reader.calls.clear

      # 1ページ目を、保存しないまま 科目表 に選び直し、その行の「読む(読み直す)」を押す
      within("#page_1_curriculum_#{@curriculum.id}") { click_on '直す' }
      choose '科目表'
      click_on '全ページを一覧で見る'
      # 種別を替えたので、読み取り結果を外す旨の確認が出る(保存の応答の警告)
      accept_confirm(/1ページの読み取り結果は外しました/) do
        within("#page_1_curriculum_#{@curriculum.id}") { click_on '読み直す' }
      end

      assert_text '読み取りが終わりました。'
    end

    assert_equal [:courses], reader.kinds # 保存済みの要件表ではなく、選び直した科目表で読まれる
    assert_equal %w[p1.png], reader.calls
    assert_equal 'courses', kinds.first
    assert_equal 'courses', find("input[name='pages[1]']:checked", visible: :all).value # 行の差し替えで、選択が戻らない
  end

  test '読み取りが終わったら、進み具合の見出しは「読み取り中」のままにしない' do
    with_reader(StubReader.new) do
      visit curriculum_path(@curriculum)
      specify '要件表', '読まない', '読まない', '読まない', '読まない'
      click_on 'この指定で読み取る(1ページ)'

      assert_text '読み取りが終わりました。'
      assert_text '読み取り済み'
      assert_no_text '読み取り中'
      assert_text '1 / 1 ページ'
    end
  end

  # 読み取り中に画面を離れて戻る。離れ方は、Turbo の遷移(画面のキャッシュを復元)と、Turbo を通らない遷移(ブラウザの復元)の2通り。
  def assert_sections_touchable
    assert_selector '#requirements_review'
    assert_no_selector '[inert]'
    assert_no_selector '[data-reading-note]'
    assert_no_selector 'progress', visible: :visible
  end

  def leave_while_reading
    with_reader(StubReader.new(delay: 3)) do
      visit curriculum_path(@curriculum)
      specify '要件表', '読まない', '読まない', '読まない', '読まない'
      click_on 'この指定で読み取る(1ページ)'
      assert_selector '#requirements_review[inert]'
      yield
      go_back
      assert_sections_touchable
    end
  end

  test '読み取り中に Turbo の遷移で別の画面へ移って戻っても、②③④の節は触れる状態に戻る' do
    leave_while_reading do
      click_on '卒業要件の確認'
      assert_current_path(%r{/requirements})
    end
  end

  test '読み取り中にブラウザの遷移で別の画面へ移って戻っても、②③④の節は触れる状態に戻る' do
    leave_while_reading { visit requirements_path }
  end

  test '保存できなかったときは、読み取りに進まず、理由を一覧の上に出す' do
    reader = StubReader.new
    with_reader(reader) do
      visit curriculum_path(@curriculum)
      specify '要件表', '読まない', '読まない', '読まない', '読まない'
      # サーバーが受けない指定を送らせる(画面を開いたあとに、知らない種別が混ざった)
      page.execute_script("document.querySelector(\"input[name='pages[1]']:checked\").value = 'bogus'")
      click_on 'この指定で読み取る(1ページ)'

      within('#pages-save-result') { assert_text '保存できなかったので、読み取りは始めませんでした。' }
      assert_text 'いずれかを、存在するページに指定してください'
      assert_no_selector 'progress', visible: :visible
    end

    assert_empty reader.calls
  end

  def first_page_is_requirements
    @curriculum.update!(pages: @curriculum.pages.map do |page|
      page['page'] == 1 ? page.merge('kind' => 'requirements') : page
    end)
  end

  # 1ページ目が、読み取りの結果(規則 humanities)を持つ要件表になっている下書き。
  def hold_a_result_on_first_page
    rule = { 'id' => 'humanities', 'type' => 'credit_sum', 'label' => '人文系', 'categories' => [],
             'required_credits' => 4 }
    pages = @curriculum.pages.map do |page|
      next page unless page['page'] == 1

      page.merge('kind' => 'requirements', 'status' => 'read', 'contributed' => { 'rules' => ['humanities'] })
    end
    @curriculum.update!(pages: pages, document: { 'rules' => [rule] })
  end
end

