# frozen_string_literal: true

require 'test_helper'

# ナビの切り替えボタンが叩く PATCH /demo_switch。セッションに年度を入れるだけで、
# 以後の画面がその学生になる（不正な年度なら2024年度のまま＝安全側）。
class DemoSwitchTest < ActionDispatch::IntegrationTest
  setup do
    host! 'localhost'
  end

  def local_env = { 'REMOTE_ADDR' => '127.0.0.1' }

  test '切り替えるとセッションに年度が入り、以後の画面がその学生になる' do
    DemoData.load!
    patch demo_switch_path(admission_year: 2025), env: local_env
    get plan_path, env: local_env
    assert_select 'body', text: /2025年度/
  end

  test '知らない年度を送っても、今までどおり2024年度のまま' do
    DemoData.load!
    patch demo_switch_path(admission_year: 1999), env: local_env
    get plan_path, env: local_env
    assert_select 'body', text: /2024年度/
  end

  test 'デモ学生が1人しかいないときは、ナビに切り替えを出さない' do
    DemoData.load!
    Curriculum.where(admission_year: 2025).destroy_all
    get plan_path, env: local_env
    assert_select 'form[action=?]', demo_switch_path, count: 0
  end

  test 'ローカルデモの外からは not_found になる' do
    patch demo_switch_path(admission_year: 2025), env: { 'REMOTE_ADDR' => '203.0.113.9' }
    assert_response :not_found
  end
end

