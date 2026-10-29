# frozen_string_literal: true

require 'test_helper'

# 卒業要件の確認画面は、学生の便覧を読み取り専用で見せる。規則の一文そのものは RequirementsHelperTest で見ている。
class RequirementsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
    DemoData.load!
    @curriculum = DemoAccount.student.curriculum
  end

  teardown do
    if @previous_proxy.nil?
      ENV.delete('LOCAL_DEMO_PROXY')
    else
      ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
    end
  end

  def local_env = { 'REMOTE_ADDR' => '127.0.0.1' }

  # 便覧は JSON 列なので、書き換えは複製に対して行い、update! で保存する。
  def change_handbook
    document = @curriculum.document.deep_dup
    yield document
    @curriculum.update!(document: document)
  end

  test '便覧の章と必要単位が出る' do
    get requirements_path, env: local_env

    assert_response :success
    assert_select 'h3', text: /1\. 共通教育/
    assert_select 'body', text: /130/
  end

  test '章ごとに必要単位と行が並ぶ' do
    get requirements_path, env: local_env

    assert_select 'section[data-group]', count: 4
    assert_select 'section[data-group="common"]' do
      assert_select 'h3', text: /1\. 共通教育/
      assert_select '[data-group-credits]', text: /30\s*単位/
      assert_select 'li[data-row]', count: 4
      assert_select 'li[data-row="health"]', text: /健康運動系.*共通教育・教養領域.*2\s*単位/m
    end
  end

  test '必要単位を持たない行は required_label を出す' do
    get requirements_path, env: local_env

    assert_select 'section[data-group="elective"] li[data-row="elective_math"]', text: /内数22単位枠/
    assert_select 'li[data-row="elective_math"] [data-row-credits]', count: 0
  end

  test '章の名前と総単位は便覧を書き換えればその通りに変わる' do
    change_handbook do |document|
      document['display']['total_credits'] = 124
      document['display']['groups'].first['title'] = '1. 別名の章'
    end

    get requirements_path, env: local_env

    assert_select 'h3', text: /1\. 別名の章/
    assert_select 'h3', text: /1\. 共通教育/, count: 0
    assert_select '[data-total-credits]', text: /124\s*単位/
  end

  test '便覧の規則がすべて、便覧の並びのまま出る' do
    get requirements_path, env: local_env

    ids = @curriculum.document.fetch('rules').pluck('id')
    assert_equal ids, css_select('li[data-rule-id]').pluck('data-rule-id')
    assert_select 'li[data-rule-id="natural_cap"]', text: /自然系.*2\s*単位/
    assert_select 'li[data-rule-id="own_fusion"]', text: /知能/
  end

  test '規則には出典のページを添える' do
    get requirements_path, env: local_env

    assert_select 'li[data-rule-id="health"]', text: /便覧10ページ/
  end

  test '区分の名前は便覧の和名で出す' do
    change_handbook do |document|
      document['categories'].find { |category| category['key'] == 'health' }['label'] = '別名の健康'
    end

    get requirements_path, env: local_env

    assert_select 'li[data-rule-id="health"]', text: /別名の健康の合計/
  end

  test '判定の途中経過は出さない' do
    get requirements_path, env: local_env

    assert_select 'body', text: /確認済み算入/, count: 0
  end

  test '編集するための部品は出ない' do
    get requirements_path, env: local_env

    assert_select 'button[onclick]', count: 0
    assert_select '[onclick], [onchange], [oninput], [onkeyup]', count: 0
    # 便覧のアップロード欄は別の節。学生の便覧を見せる部分には、編集の部品を置かない。
    %w[button input textarea select form].each do |tag|
      assert_select "main section:not([data-curriculum-import]) #{tag}", count: 0
    end
    assert_select 'main script', count: 0
    assert_select 'body', text: /ルールビルダー|要件を保存|ルート区分を追加|リセット/, count: 0
  end

  test '規則の型が未知の便覧でも画面は開く' do
    change_handbook do |document|
      document['rules'] << { 'id' => 'gpa', 'type' => 'gpa', 'label' => 'GPA' }
    end

    get requirements_path, env: local_env

    assert_response :success
    assert_select 'body', text: /解釈できません/
    assert_select 'li[data-rule-id="gpa"][data-rule-status="unknown"] .text-red-700', text: /gpa.*解釈できません/
    # 読めない規則だけが赤くなり、ほかの規則は読める
    assert_select 'li[data-rule-status="unknown"]', count: 1
  end

  test '判定側が弾く便覧は、他の画面と同じく画面を開かずに例外にする' do
    change_handbook do |document|
      document['categories'] << document['categories'].first.dup
    end

    error = assert_raises(ArgumentError) { get requirements_path, env: local_env }
    assert_match(/categories の key が重複/, error.message)
  end

  test '規則が存在しない区分を指す便覧も開かない' do
    change_handbook do |document|
      document['rules'] << { 'id' => 'ghost', 'type' => 'credit_sum', 'label' => 'x', 'categories' => ['nowhere'],
                             'required_credits' => 1 }
    end

    assert_raises(ArgumentError) { get requirements_path, env: local_env }
  end

  test '入れ子の奥の読めない選択肢は、その規則の側でも見つけられる' do
    change_handbook do |document|
      document['rules'] << { 'id' => 'gpa', 'type' => 'gpa', 'label' => 'GPA' }
      document['rules'].find { |rule| rule['id'] == 'foreign_language' }['options'] << { 'type' => 'gpa' }
    end

    get requirements_path, env: local_env

    assert_equal %w[foreign_language gpa], css_select('li[data-rule-status="unknown"]').pluck('data-rule-id')
    assert_select 'li[data-rule-id="foreign_language"] div.text-red-700', text: /要確認になります.*外国語の選択経路/m
  end

  test '選択肢が空の規則は赤で出る' do
    change_handbook do |document|
      document['rules'].find { |rule| rule['id'] == 'foreign_language' }['options'] = []
    end

    get requirements_path, env: local_env

    assert_select 'li[data-rule-id="foreign_language"][data-rule-status="unknown"] .text-red-700', text: /選択肢が空です/
  end

  test '系列が混在したときの確認事項が出る' do
    get requirements_path, env: local_env

    assert_select 'li[data-rule-id="calculus"]', text: /系列が混在したとき：/
  end
end

