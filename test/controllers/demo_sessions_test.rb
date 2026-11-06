# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

# デモの入口。認証が入る前から公開している画面なので、
# どこから叩けるかの条件はログイン後の画面とは別に持っている。
class DemoSessionsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
  end

  teardown do
    @previous_proxy.nil? ? ENV.delete('LOCAL_DEMO_PROXY') : ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
    ENV.delete('PUBLIC_DEMO')
  end

  def local_env = { 'REMOTE_ADDR' => '127.0.0.1' }

  test 'ローカルからならデモ学生としてログインできる' do
    assert_difference 'Session.count', 1 do
      post demo_session_path, env: local_env
    end

    assert_redirected_to root_path
    assert_equal DemoAccount::EMAIL, Session.last.user.email

    get root_path, env: local_env
    assert_response :success
  end

  test 'ログイン画面にデモの導線が出る' do
    get new_session_path, env: local_env

    assert_select 'form[action=?]', demo_session_path, count: 1
  end

  test '公開アドレスからは入れず、転送ヘッダーを偽っても同じ' do
    assert_demo_denied('REMOTE_ADDR' => '203.0.113.20', 'HTTP_X_FORWARDED_FOR' => '127.0.0.1')
  end

  test 'ループバックでもホスト名が違えば入れない' do
    host! 'www.example.com'
    assert_demo_denied(local_env)
  end

  test '私設プロキシは明示的に許可したときだけ通す' do
    proxy_env = { 'REMOTE_ADDR' => '172.19.0.1' }
    assert_demo_denied(proxy_env)

    ENV['LOCAL_DEMO_PROXY'] = '1'
    assert_difference 'Session.count', 1 do
      post demo_session_path, env: proxy_env
    end
    assert_redirected_to root_path

    host! 'www.example.com'
    assert_demo_denied(proxy_env)
  end

  test '本番では、許可したプロキシからでも入れない' do
    ENV['LOCAL_DEMO_PROXY'] = '1'
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new('production')) do
      assert_demo_denied(local_env)
      assert_demo_denied('REMOTE_ADDR' => '172.19.0.1')
    end
  end

  test 'PUBLIC_DEMO を立てた環境では、どのホストからでも入れる' do
    host! 'grc.example.com'
    assert_demo_denied('REMOTE_ADDR' => '203.0.113.10')

    ENV['PUBLIC_DEMO'] = '1'
    assert_difference 'Session.count', 1 do
      post demo_session_path, env: { 'REMOTE_ADDR' => '203.0.113.10' }
    end
    assert_redirected_to root_path
  end

  test 'デモの導線を出さない環境では、ログイン画面にもボタンを出さない' do
    get new_session_path, env: { 'REMOTE_ADDR' => '203.0.113.10' }

    assert_response :success
    assert_select 'form[action=?]', demo_session_path, count: 0
  end

  private

  # 入れないうえ、デモデータも作られないこと。
  def assert_demo_denied(request_env)
    assert_no_difference %w[Session.count User.count Student.count StudentCourse.count] do
      post demo_session_path, env: request_env
    end
    assert_response :not_found
  end
end

