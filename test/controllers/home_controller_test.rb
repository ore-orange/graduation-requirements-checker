# frozen_string_literal: true

require 'test_helper'

class HomeControllerTest < ActionDispatch::IntegrationTest
  test 'ルートにアクセスできる' do
    get root_url

    assert_response :success
  end
end

