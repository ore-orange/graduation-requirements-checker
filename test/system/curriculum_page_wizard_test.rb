# frozen_string_literal: true

require 'application_system_test_case'

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
    choose '要件表'
    choose '科目表'
    choose '科目表'
    choose '読まない'
    choose '要件表' # 5ページ目の次で、一覧になる

    assert_text '指定の確認'
    assert_text '要件表 2 ・ 科目表 2 ・ 読まない 1'
    assert_button 'この指定で読み取る(4ページ)', disabled: true
    within("#page_2_curriculum_#{@curriculum.id}") { assert_text '科目表' }
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
end

