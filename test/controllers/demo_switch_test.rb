# frozen_string_literal: true

require 'test_helper'

# ナビの切り替えボタンが叩く PATCH /demo_switch。セッションに年度を入れるだけで、
# 以後の画面がその学生になる（不正な年度・実在しない年度なら2024年度のまま＝安全側）。
#
# ダッシュボードの「卒業に必要な単位」の分母(2024年度便覧は130単位、2025年度便覧は124単位)で見分ける。
# 履修計画表の学期見出し「(○年度)」は admission_year ではなく実行時の実カレンダー年度を表すだけなので、
# どちらの学生でも今日の日付次第で同じ値になりうるため、切り替えの確認には使えない。ナビの切り替え
# ボタンのラベル("2025年度"/"2024年度")も、候補がある限りどちらを選んでいても両方出るので、同じ理由で
# 使えない(切り替えが実際には効いていなくても一致してしまい、テストが何も確かめないことになる)。
class DemoSwitchTest < ActionDispatch::IntegrationTest
  setup do
    host! 'localhost'
  end

  def local_env = { 'REMOTE_ADDR' => '127.0.0.1' }

  test '切り替えるとセッションに年度が入り、以後の画面がその学生になる' do
    DemoData.load!
    patch demo_switch_path(admission_year: 2025), env: local_env
    get root_path, env: local_env
    assert_select 'body', text: %r{/\s*124\s*単位}
  end

  test '知らない年度を送っても、今までどおり2024年度のまま' do
    DemoData.load!
    patch demo_switch_path(admission_year: 1999), env: local_env
    get root_path, env: local_env
    assert_select 'body', text: %r{/\s*130\s*単位}
  end

  test 'デモ学生が1人しかいないときは、ナビに切り替えを出さない' do
    # destroy_all は Curriculum の restrict_with_error に静かに阻まれる(学生が既に居るので消せない)ため、
    # DemoData.load! の前に便覧を未公開へ戻し、2025年度のデモ学生自体を作らせない。
    Curriculum.find_by!(admission_year: 2025).update!(published_at: nil)
    DemoData.load!
    get plan_path, env: local_env
    # 実際の action は demo_switch_path(admission_year: ...) のクエリ付き("/demo_switch?admission_year=..")
    # になるので、前方一致で見る。
    assert_select 'form[action^="/demo_switch"]', count: 0
  end

  test '便覧が未公開で実在しない年度へ切り替えても、次の画面はロックアウトせず2024年度のまま' do
    Curriculum.find_by!(admission_year: 2025).update!(published_at: nil)
    DemoData.load!
    patch demo_switch_path(admission_year: 2025), env: local_env
    get root_path, env: local_env
    assert_response :success
    assert_select 'body', text: %r{/\s*130\s*単位}
  end

  test 'ローカルデモの外からは not_found になる' do
    patch demo_switch_path(admission_year: 2025), env: { 'REMOTE_ADDR' => '203.0.113.9' }
    assert_response :not_found
  end
end

