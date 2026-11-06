# frozen_string_literal: true

require 'test_helper'

class SessionsTest < ActionDispatch::IntegrationTest
  PASSWORD = 'a-test-password'

  setup do
    host! 'localhost'
    @user = User.create!(email: 'student@example.test', password: PASSWORD)
  end

  test 'ログイン画面は未ログインでも開ける' do
    get new_session_path

    assert_response :success
    assert_select 'form[action=?]', session_path
    # 行き先がないので、ログイン前はタブを出さない
    assert_select 'nav', count: 0
  end

  test '正しいメールアドレスとパスワードでログインできる' do
    assert_difference 'Session.count', 1 do
      post session_path, params: { email: @user.email, password: PASSWORD }
    end

    assert_redirected_to root_url
    assert_equal @user, Session.last.user
  end

  test 'メールアドレスの大文字小文字と前後の空白は無視する' do
    post session_path, params: { email: " #{@user.email.upcase} ", password: PASSWORD }

    assert_redirected_to root_url
  end

  test 'パスワードが違えばログインさせず、理由も明かさない' do
    assert_no_difference 'Session.count' do
      post session_path, params: { email: @user.email, password: 'wrong' }
    end

    assert_redirected_to new_session_path
    # 登録済みのメールアドレスを探られないよう、どちらが違うかは言わない
    assert_equal 'メールアドレスまたはパスワードが違います。', flash[:alert]
  end

  test '存在しないメールアドレスでも同じ文言を返す' do
    post session_path, params: { email: 'nobody@example.test', password: PASSWORD }

    assert_redirected_to new_session_path
    assert_equal 'メールアドレスまたはパスワードが違います。', flash[:alert]
  end

  test 'ログアウトするとセッションが消え、もう開けない' do
    sign_in_as(@user)

    assert_difference 'Session.count', -1 do
      delete session_path
    end
    assert_redirected_to new_session_path

    get root_path
    assert_redirected_to new_session_path
  end

  test '未ログインで開こうとした画面に、ログイン後そのまま戻る' do
    get plan_path
    assert_redirected_to new_session_path

    post session_path, params: { email: @user.email, password: PASSWORD }

    assert_redirected_to plan_url
  end

  test '画面ではない操作を弾いたときは、ログイン後に最初の画面へ送る' do
    # POST のURLを控えてしまうと、ログイン後に GET されて404になる
    post plan_courses_path, params: { course_key: 'anything' }
    assert_redirected_to new_session_path

    post session_path, params: { email: @user.email, password: PASSWORD }

    assert_redirected_to root_url
  end
end

