# frozen_string_literal: true

require 'test_helper'

# 卒業ダッシュボードの見え方。数字そのものの正しさは
# GraduationAssessmentTest と DashboardMetricsTest で見ている。
class DashboardTest < ActionDispatch::IntegrationTest
  GROUPS = %w[common basic required elective].freeze

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
    DemoData.load!
    @student = DemoAccount.student
    @student.planned_courses.delete_all
  end

  teardown do
    if @previous_proxy.nil?
      ENV.delete('LOCAL_DEMO_PROXY')
    else
      ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
    end
  end

  def local_env = { 'REMOTE_ADDR' => '127.0.0.1' }

  test '区分ごとに独立したカードが並ぶ' do
    get root_path, env: local_env

    assert_response :success
    assert_select 'details[data-check]', count: GROUPS.size
    %w[common_total basic_total required_all elective_total].each do |check_id|
      assert_select 'details[data-check=?]', check_id, count: 1
    end
  end

  test 'カードの見出しに通し番号は出さない' do
    get root_path, env: local_env

    assert_select 'details[data-check="common_total"] h4', text: /\A共通教育\z/
    assert_select 'h4', text: /\A1\. /, count: 0
  end

  test '画面名の見出しは読み上げ用だけで、本文には出さない' do
    get root_path, env: local_env

    # ヘッダーのタブで現在地が分かるので、大きな見出しは置かない
    assert_select 'h2.sr-only', text: '卒業ダッシュボード', count: 1
    assert_select 'h2:not(.sr-only)', count: 0
  end

  test 'ヘッダーのタブが4画面ぶんある' do
    get root_path, env: local_env

    [[root_path, '卒業ダッシュボード'], [requirements_path, '卒業要件の確認'],
     [plan_path, '履修計画表'], [profile_path, 'マイページ']].each do |path, label|
      assert_select 'nav a[href=?]', path, text: label
    end
    assert_select 'nav a[aria-current="page"]', text: '卒業ダッシュボード'
  end

  test '充足した区分は充足のバッジだけを出す' do
    get root_path, env: local_env

    assert_select 'details[data-check="basic_total"]' do
      assert_select '.status-satisfied', text: '充足', count: 1
      assert_select '.status-unmet', count: 0
      assert_select '.status-in-progress', count: 0
    end
  end

  test '不足している区分で履修中があれば両方のバッジを出す' do
    get root_path, env: local_env

    # 専門選択科目は修得22単位・履修中2単位で、必要37単位に届いていない
    assert_select 'details[data-check="elective_total"]' do
      assert_select '.status-unmet', text: '不足', count: 1
      assert_select '.status-in-progress', text: '履修中', count: 1
    end
  end

  test '履修中がない区分には履修中のバッジを出さない' do
    get root_path, env: local_env

    # 共通教育は24単位どまりで、履修中の科目はひとつもない
    assert_select 'details[data-check="common_total"]' do
      assert_select '.status-unmet', text: '不足', count: 1
      assert_select '.status-in-progress', count: 0
    end
  end

  test 'バーは量だけを表し、判定では色を変えない' do
    get root_path, env: local_env

    # 充足していても足りなくても、修得済みは同じ緑
    assert_select 'details[data-check="basic_total"] .bg-emerald-500', count: 1
    assert_select 'details[data-check="required_all"] .bg-emerald-500', count: 1
    # 履修中ぶんは水色。足りているかどうかは判定バッジが受け持つ
    assert_select 'details[data-check="elective_total"] .bg-sky-400', count: 1
    assert_select '.bg-amber-300', count: 0
  end

  test '閉じているあいだは内訳を送らない' do
    get root_path, env: local_env

    GROUPS.each do |id|
      assert_select "turbo-frame#dashboard-group-#{id}[src][loading=?]", 'lazy', count: 1
    end
    # 内訳の中身そのものはまだ含まれない
    assert_select '[data-check="health"]', count: 0
  end

  test '内訳は開いたときに返る' do
    get dashboard_group_path('common'), env: local_env

    assert_response :success
    assert_select 'turbo-frame#dashboard-group-common' do
      assert_select 'ul > li', count: 4
      assert_select 'li[data-check="health"][data-status="satisfied"]', count: 1
    end
  end

  test '必要単位を持たない行はバーも判定も出さない' do
    get dashboard_group_path('elective'), env: local_env

    # 数学基礎(選択)・知能情報関連・専門科目(自由)は上位の枠に寄与するだけの行
    %w[elective_math related free].each do |id|
      assert_select "li[data-check=\"#{id}\"][data-status=\"contribution\"]" do
        assert_select '.demo-status', count: 0
        assert_select '.bg-emerald-500, .bg-sky-400', count: 0
      end
    end
    # 3区分でひとつの22単位枠は、アドバンストの行がまとめて受け持つ
    assert_select 'li[data-check="advanced"][data-status="satisfied"] .bg-emerald-500', count: 1
  end

  test '内訳は狭い画面でも横に溢れない' do
    get dashboard_group_path('common'), env: local_env

    # 固定幅の表をやめ、積んで見せる。横スクロールの退避先も持たない。
    assert_select 'table', count: 0
    assert_select '.overflow-x-auto', count: 0
    assert_select 'li[data-check="health"]', count: 1
  end

  test '内訳に区分名の繰り返しや設計用語を出さない' do
    get dashboard_group_path('common'), env: local_env

    # 開いた時点でどの区分かは分かるので、見出しを繰り返さない
    assert_select 'h5', count: 0
    assert_no_match(/小項目/, response.body)
    assert_no_match(/共通教育の内訳/, response.body)
  end

  test '未修得の必修は内訳の先頭にまとめて出す' do
    get dashboard_group_path('required'), env: local_env

    assert_response :success
    assert_match(/未修得・未計画の必修/, response.body)
    assert_match(/卒業研究Ⅰ/, response.body)
  end

  test '未修得の必修がなければその行は出さない' do
    get dashboard_group_path('common'), env: local_env

    assert_no_match(/未修得・未計画の必修/, response.body)
  end

  test '内訳は画面まるごとではなくフレームだけを返す' do
    get dashboard_group_path('basic'), env: local_env

    assert_select 'nav', count: 0
    assert_select 'details', count: 0
  end

  test '存在しない区分は404' do
    get dashboard_group_path('nope'), env: local_env

    assert_response :not_found
  end

  test '本番やリモートからは開けない' do
    get root_path, env: { 'REMOTE_ADDR' => '203.0.113.10' }

    assert_response :not_found
  end
end

