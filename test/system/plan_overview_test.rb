# frozen_string_literal: true

require 'application_system_test_case'

class PlanOverviewTest < ApplicationSystemTestCase
  setup { travel_to Date.new(2026, 10, 26) }
  teardown { travel_back }

  test '一覧で押したマスの学期に科目を追加できる' do
    visit new_session_path
    click_on 'デモアカウントで見る'
    assert_no_current_path new_session_path

    student = DemoAccount.student
    student.planned_courses.delete_all

    visit plan_path(view: 'all')
    find('[data-overview-add-button="related:4-後期"]').click

    within('dialog[open]') do
      assert_text '4年 後期に追加'
      click_on '予定に追加'
    end

    assert_selector '[data-overview-cell="related:4-後期"] [data-plan]', count: 1
    assert_equal [[2027, '後期']], student.planned_courses.reload.pluck(:academic_year, :semester)
  end
end

