# frozen_string_literal: true

require 'application_system_test_case'

# 卒業要件の確認画面の「対象を選ぶ」。学部を選んだら、その学部の学科だけが選べる。
#
# 選択肢を hidden/disabled にするだけでは足りない。<optgroup>/<option> の hidden を無視するブラウザ
# (Safari など)があり、そこでは他の学部の学科がプルダウンに出たままになる。だからこのテストは
# 「見えない」ではなく「DOM に無い」ことを見る。
class RequirementsSelectorTest < ApplicationSystemTestCase
  # プルダウンの中に残っている <optgroup> の label(= 親の名前)。
  def group_labels(field)
    find_field(field, disabled: :all).all('optgroup', visible: :all).pluck(:label)
  end

  # プルダウンに並んでいる選択肢の名前(空の「---------」は除く)。
  def option_texts(field)
    find_field(field, disabled: :all).all('option').map(&:text).reject { |text| text.start_with?('---') }
  end

  test '学部を選ぶと、その学部の学科だけが学科のプルダウンに残る' do
    visit requirements_path
    assert_empty group_labels('学科') # 学部を選ぶまでは、学科は「---------」だけ

    select '理学部', from: '学部'

    assert_equal ['理学部'], group_labels('学科')
    assert_equal ['数理科学科'], option_texts('学科')

    select '工学部', from: '学部' # 選び直せば、外した学科は元の位置に戻る

    assert_equal ['工学部'], group_labels('学科')
    assert_equal ['工学科'], option_texts('学科')
  end

  test '学科を選ぶと、その学科のコースだけがコースのプルダウンに残る' do
    visit requirements_path

    select '工学部', from: '学部'
    select '工学科', from: '学科'

    assert_equal ['工学科'], group_labels('コース')
  end

  test '学部を選び直すと、前の学部の学科は選択ごと消える' do
    visit requirements_path

    select '工学部', from: '学部'
    select '工学科', from: '学科'
    select '理学部', from: '学部'

    assert_equal ['理学部'], group_labels('学科')
    assert_equal '', find_field('学科').value
  end
end

