# frozen_string_literal: true

require 'test_helper'

class HomeControllerTest < ActionDispatch::IntegrationTest
  test 'ルートにアクセスできる' do
    get root_url

    assert_response :success
  end

  test 'アプリ名が h1 に表示される' do
    get root_url

    assert_select 'h1', text: ApplicationHelper::APP_NAME
  end

  test 'ページタイトルにアプリ名が入る' do
    get root_url

    assert_select 'title', text: ApplicationHelper::APP_NAME
  end
end

