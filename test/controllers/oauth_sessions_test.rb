# frozen_string_literal: true

require 'test_helper'

class OauthSessionsTest < ActionDispatch::IntegrationTest
  UID = '109876543210987654321'
  EMAIL = 'student@ie.u-ryukyu.ac.jp'

  setup do
    host! 'localhost'
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test 'はじめてのGoogleログインで利用者が作られる' do
    mock_google

    assert_difference ['User.count', 'Session.count'], 1 do
      sign_in_with_google
    end

    assert_redirected_to root_url
    user = User.last
    assert_equal UID, user.google_uid
    assert_equal EMAIL, user.email
  end

  test '2回目は同じ利用者を使い回す' do
    mock_google
    sign_in_with_google
    sign_out

    assert_no_difference 'User.count' do
      sign_in_with_google
    end
  end

  test 'Google側でメールアドレスが変わっても同じ利用者として扱う' do
    mock_google
    sign_in_with_google
    sign_out

    mock_google(email: 'renamed@ie.u-ryukyu.ac.jp')
    assert_no_difference 'User.count' do
      sign_in_with_google
    end

    assert_equal UID, User.last.google_uid
  end

  test 'パスワードで登録済みの人が同じメールアドレスでGoogleを使っても増えない' do
    user = User.create!(email: EMAIL, password: 'a-test-password')
    mock_google

    assert_no_difference 'User.count' do
      sign_in_with_google
    end

    assert_equal UID, user.reload.google_uid
  end

  test 'Google側で断られたらログイン画面へ戻す' do
    OmniAuth.config.mock_auth[:google_oauth2] = :access_denied

    assert_no_difference 'Session.count' do
      post oauth_request_path(:google_oauth2)
      follow_redirect!
    end

    assert_redirected_to new_session_path
  end

  # OmniAuth 2.x は GET での開始を拒む（CVE-2015-9284）
  test 'GETではGoogleログインを始められない' do
    get '/auth/google_oauth2'

    assert_response :not_found
  end

  private

  def mock_google(uid: UID, email: EMAIL)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: 'google_oauth2', uid: uid, info: { email: email, name: 'テスト 学生' }
    )
  end

  def sign_in_with_google
    post oauth_request_path(:google_oauth2)
    follow_redirect!
  end
end

