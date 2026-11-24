# frozen_string_literal: true

require 'application_system_test_case'

class DashboardTooltipTest < ApplicationSystemTestCase
  setup { travel_to Date.new(2026, 10, 26) }
  teardown { travel_back }

  test 'ゲージにホバーすると、カーソルの位置に不足・予定・履修済みの単位が最前面に出る' do
    SampleStudent.load!
    visit new_session_path
    fill_in 'メールアドレス', with: SampleStudent::EMAIL
    fill_in 'パスワード', with: SampleStudent::PASSWORD
    click_on 'ログイン'
    assert_no_current_path new_session_path

    visit root_path
    gauge = first('[data-controller="bar-tooltip"]')
    assert_no_selector '[popover]:popover-open'

    gauge.hover
    tip = find('[popover]:popover-open')
    assert_match(/不足: \d+単位\s*予定: \d+単位\s*履修済み: \d+単位/, tip.text)

    # ホバーはゲージの中央に乗るので、ツールチップの左上はその少し右下にある
    gauge_box = gauge.evaluate_script('this.getBoundingClientRect().toJSON()')
    tip_box = tip.evaluate_script('this.getBoundingClientRect().toJSON()')
    center_x = gauge_box['left'] + (gauge_box['width'] / 2)
    center_y = gauge_box['top'] + (gauge_box['height'] / 2)
    assert_in_delta center_x + 12, tip_box['left'], 2
    assert_in_delta center_y + 12, tip_box['top'], 2

    find('h1, h2', match: :first).hover
    assert_no_selector '[popover]:popover-open'
  end
end

