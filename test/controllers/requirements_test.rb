# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

# 卒業要件の確認画面は、学部・学科コース・入学年度を選んでから、その便覧を読み取り専用で見せる。
# 規則の一文そのものは RequirementsHelperTest で見ている。
class RequirementsTest < ActionDispatch::IntegrationTest
  FACULTY = '工学部'
  DEPARTMENT = '工学科 知能情報コース'

  setup do
    @previous_proxy = ENV.delete('LOCAL_DEMO_PROXY')
    host! 'localhost'
    # 画面は学生ではなく選んだ組み合わせから便覧を引く。デモ学生は要らない。
    @curriculum = Curriculum.published.find_by!(slug: 'intelligent_informatics', admission_year: 2024)
  end

  teardown do
    if @previous_proxy.nil?
      ENV.delete('LOCAL_DEMO_PROXY')
    else
      ENV['LOCAL_DEMO_PROXY'] = @previous_proxy
    end
  end

  def local_env = { 'REMOTE_ADDR' => '127.0.0.1' }

  # 選んだ組み合わせ。何も上書きしなければ、2024年度入学の公開済みの便覧になる。
  def selection(faculty: FACULTY, department: DEPARTMENT, admission_year: 2024)
    { faculty: faculty, department: department, admission_year: admission_year }
  end

  def show_selected(**overrides) = get(requirements_path(selection(**overrides)), env: local_env)

  def create_draft(admission_year: 2030, department: DEPARTMENT, faculty: FACULTY, **attributes)
    Curriculum.create!(slug: 'draft_course', admission_year: admission_year, faculty_name: faculty,
                       department_name: department, source_filename: 'draft.pdf', pages: Curriculum.blank_pages(2),
                       **attributes)
  end

  # 便覧は JSON 列なので、書き換えは複製に対して行い、update! で保存する。
  def change_handbook
    document = @curriculum.document.deep_dup
    yield document
    @curriculum.update!(document: document)
  end

  # ---- 選ぶ ----

  test '何も選んでいないときは、卒業要件を出さずに選択だけ出す' do
    get requirements_path, env: local_env

    assert_response :success
    assert_select 'select[name=admission_year]'
    assert_select 'select[name=faculty]'
    assert_select 'select[name=department]'
    assert_select '[data-total-credits]', count: 0
    assert_select 'section[data-group]', count: 0
    # 「公開済みの便覧」「下書き」のカード一覧は、選択で辿れるので出さない
    assert_select '[data-published-curricula], [data-draft-curricula]', count: 0
    assert_select 'body', text: /公開済みの便覧|作業中の下書き/, count: 0
  end

  test '選択肢は、便覧に実在する学部・学科コース・入学年度から作る(年度は新しい順)' do
    get requirements_path, env: local_env

    assert_select 'select[name=faculty] option[value=?]', FACULTY
    assert_select 'select[name=department] optgroup[label=?] option[value=?]', FACULTY, DEPARTMENT
    assert_equal %w[2025 2024], css_select('select[name=admission_year] option').pluck('value').compact_blank.first(2)
  end

  test '学部名か学科コース名を持たない便覧は、選択肢にしない(空の選択肢を作らない)' do
    Curriculum.create!(slug: 'no_names', admission_year: 1999, source_filename: 'n.pdf', pages: [])

    get requirements_path, env: local_env

    assert_select 'select[name=admission_year] option[value="1999"]', count: 0
    # 空の値の選択肢は、各欄の「選んでください」だけ
    assert_select 'select option[value=""]', count: 3
  end

  test '選択は GET で送る。再読込やブックマークで壊れないよう、セッションには隠さない' do
    get requirements_path, env: local_env

    assert_select 'form[method=get][action=?]', requirements_path do
      assert_select 'input[type=submit], button[type=submit]', count: 1
    end
    assert_select 'form[method=get] input[name=authenticity_token]', count: 0
  end

  test '選ぶとその年度の卒業要件が出る' do
    show_selected

    assert_response :success
    assert_select '[data-total-credits]', text: /130/
    # 選んだ値は選択欄に残る
    assert_select 'select[name=admission_year] option[selected][value="2024"]'
    assert_select 'select[name=faculty] option[selected][value=?]', FACULTY
  end

  test '年度を替えると、その年度の便覧が出る' do
    other = Curriculum.published.find_by!(slug: 'intelligent_informatics', admission_year: 2025)
    other.update!(document: other.document.deep_merge('display' => { 'total_credits' => 126 }))

    show_selected(admission_year: 2025)

    assert_select '[data-total-credits]', text: /126/
    assert_select '[data-total-credits]', text: /130/, count: 0
  end

  # ---- 3つの状態 ----

  test '公開済みを選ぶと、編集するボタンが出る。押すと既存の「複製して直す」に飛ぶ' do
    show_selected

    assert_select 'form[action=?][method=post]', duplicate_curriculum_path(@curriculum), count: 1
    assert_select 'form[action=?] button, form[action=?] input[type=submit]',
                  duplicate_curriculum_path(@curriculum), duplicate_curriculum_path(@curriculum),
                  text: /この卒業要件を編集する/, count: 1
    assert_select 'body', text: /この年度の便覧はまだありません/, count: 0
  end

  test '編集するボタンを押すと、公開済みを書き換えずに下書きができる' do
    before = @curriculum.reload.attributes

    assert_difference('Curriculum.drafts.count', 1) { post duplicate_curriculum_path(@curriculum), env: local_env }

    assert_redirected_to curriculum_path(Curriculum.drafts.order(:id).last)
    assert_equal before, @curriculum.reload.attributes
  end

  test '下書きだけがある組み合わせを選ぶと、下書きの確認を続けるリンクが出る' do
    draft = create_draft

    show_selected(admission_year: 2030)

    assert_response :success
    assert_select 'a[href=?]', curriculum_path(draft), text: /下書きの確認を続ける/
    assert_select '[data-total-credits]', count: 0
    assert_select 'form[action=?]', duplicate_curriculum_path(@curriculum), count: 0
  end

  test '公開済みと下書きが両方ある組み合わせでは、要件を出し、下書きへ続くリンクを編集ボタンの代わりに出す' do
    # 編集ボタンを何度も押して、同じ年度の下書きを増やさせないため
    draft = create_draft(admission_year: 2024)

    show_selected

    assert_select '[data-total-credits]', text: /130/
    assert_select 'a[href=?]', curriculum_path(draft), text: /下書きの確認を続ける/
    assert_select 'form[action=?]', duplicate_curriculum_path(@curriculum), count: 0
  end

  test '下書きが複数あれば、すべて続きのリンクにする' do
    first = create_draft
    second = create_draft

    show_selected(admission_year: 2030)

    assert_select 'a[href=?]', curriculum_path(first)
    assert_select 'a[href=?]', curriculum_path(second)
  end

  test '便覧の無い年度を選ぶと、無いと伝え、PDFから作る導線が出る' do
    show_selected(admission_year: 2030)

    assert_response :success
    assert_select 'body', text: /この年度の便覧はまだありません/
    assert_select 'form[action=?][enctype="multipart/form-data"]', curricula_path
    assert_select '[data-total-credits]', count: 0
    assert_select 'form[action*=duplicate]', count: 0
  end

  test '何も選んでいないときも、選択肢にない年度の便覧を作り始める入口がある' do
    get requirements_path, env: local_env

    assert_select 'details form[action=?][enctype="multipart/form-data"]', curricula_path
  end

  # ---- 変な指定でも、落ちず、他のコースの便覧を出さない ----

  test '存在しない学部を指定すると、「ありません」の状態になる' do
    show_selected(faculty: '存在しない学部')

    assert_response :success
    assert_select 'body', text: /この年度の便覧はまだありません/
    assert_select '[data-total-credits]', count: 0
  end

  test '年度が数字でない・範囲外・便覧のない値でも、落ちずに「ありません」になる' do
    ['abc', '', ' ', '2024abc', '20.5', '-1', '0', '10000', '99999999999999999999999', '０'].each do |year|
      next if year.blank? # 空は「選んでいない」(別のテスト)

      show_selected(admission_year: year)

      assert_response :success, "年度 #{year.inspect} で落ちた"
      assert_select '[data-total-credits]', count: 0
      assert_select 'body', text: /この年度の便覧はまだありません/
    end
  end

  test '指定が3つ揃っていないときは、選択だけを出し、足りないものを伝える' do
    get requirements_path(faculty: FACULTY), env: local_env

    assert_response :success
    assert_select '[data-total-credits]', count: 0
    assert_select '[data-selection-incomplete]'
    assert_select 'select[name=faculty] option[selected][value=?]', FACULTY
    assert_select 'body', text: /この年度の便覧はまだありません/, count: 0
  end

  test '別の学部の学科コースを組み合わせても、他のプログラムの便覧は出さない' do
    other = Curriculum.create!(slug: 'other_course', admission_year: 2024, faculty_name: '理学部',
                               department_name: '数理科学科', title: '別コースの便覧', published_at: Time.current,
                               document: @curriculum.document.merge('title' => '別コースの便覧'))

    show_selected(faculty: '理学部') # 学科コースは工学部のもの

    assert_response :success
    assert_select 'body', text: /別コースの便覧/, count: 0
    assert_select '[data-total-credits]', count: 0
    assert_select 'form[action=?]', duplicate_curriculum_path(other), count: 0

    show_selected(faculty: '理学部', department: '数理科学科')

    assert_select 'p', text: /別コースの便覧/
  end

  test '配列やハッシュで送られた指定でも落ちない' do
    ['faculty[]=x&department[]=y&admission_year[]=1',
     'faculty[a]=x&department[a]=y&admission_year[a]=1'].each do |query|
      get "/requirements?#{query}", env: local_env

      assert_response :success, "#{query} で落ちた"
      assert_select '[data-total-credits]', count: 0
    end
  end

  test '制御文字や長すぎる値でも落ちず、そのまま画面に出さない' do
    show_selected(faculty: "#{FACULTY}\0")
    assert_response :success
    assert_select '[data-total-credits]', count: 0

    long = 'あ' * 5000
    show_selected(faculty: long)
    assert_response :success
    assert_operator response.body.scan('あ').size, :<, 1000

    # 壊れたエンコードは、コントローラに届く前にフレームワークが 400 で断る（500 にはならない）
    get '/requirements?faculty=%FF%FE&department=%FF&admission_year=2024', env: local_env
    assert_response :bad_request
  end

  test '指定に含まれる HTML はエスケープして出す' do
    show_selected(faculty: '<script>alert(1)</script>')

    assert_response :success
    assert_select 'main script', count: 0
    assert_select 'body', text: %r{<script>alert\(1\)</script>}
  end

  test '何も選んでいないときは、読み込み時の検査(Catalogue)を呼ばない' do
    GraduationAssessment::Catalogue.stub(:new, ->(*) { raise 'Catalogue を呼んだ' }) do
      get requirements_path, env: local_env
      assert_response :success

      show_selected(admission_year: 2030)
      assert_response :success
    end
  end

  # ---- ローカル限定 ----

  test '外部からは、選択も便覧も見えない' do
    [{ 'REMOTE_ADDR' => '203.0.113.20', 'HTTP_X_FORWARDED_FOR' => '127.0.0.1' }, local_env].each do |request_env|
      host! 'www.example.com' if request_env == local_env
      get requirements_path, env: request_env
      assert_response :not_found
      get requirements_path(selection), env: request_env
      assert_response :not_found
      assert_select 'select', count: 0
      assert_select '[data-total-credits]', count: 0
    end
  end

  test '本番では、ローカルからでも開かない' do
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new('production')) do
      get requirements_path(selection), env: local_env
      assert_response :not_found
    end
  end

  test '便覧の章と必要単位が出る' do
    show_selected

    assert_response :success
    assert_select 'h3', text: /1\. 共通教育/
    assert_select 'body', text: /130/
  end

  test '章ごとに必要単位と行が並ぶ' do
    show_selected

    assert_select 'section[data-group]', count: 4
    assert_select 'section[data-group="common"]' do
      assert_select 'h3', text: /1\. 共通教育/
      assert_select '[data-group-credits]', text: /30\s*単位/
      assert_select 'li[data-row]', count: 4
      assert_select 'li[data-row="health"]', text: /健康運動系.*共通教育・教養領域.*2\s*単位/m
    end
  end

  test '必要単位を持たない行は required_label を出す' do
    show_selected

    assert_select 'section[data-group="elective"] li[data-row="elective_math"]', text: /内数22単位枠/
    assert_select 'li[data-row="elective_math"] [data-row-credits]', count: 0
  end

  test '章の名前と総単位は便覧を書き換えればその通りに変わる' do
    change_handbook do |document|
      document['display']['total_credits'] = 124
      document['display']['groups'].first['title'] = '1. 別名の章'
    end

    show_selected

    assert_select 'h3', text: /1\. 別名の章/
    assert_select 'h3', text: /1\. 共通教育/, count: 0
    assert_select '[data-total-credits]', text: /124\s*単位/
  end

  test '便覧の規則がすべて、便覧の並びのまま出る' do
    show_selected

    ids = @curriculum.document.fetch('rules').pluck('id')
    assert_equal ids, css_select('li[data-rule-id]').pluck('data-rule-id')
    assert_select 'li[data-rule-id="natural_cap"]', text: /自然系.*2\s*単位/
    assert_select 'li[data-rule-id="own_fusion"]', text: /知能/
  end

  test '規則には出典のページを添える' do
    show_selected

    assert_select 'li[data-rule-id="health"]', text: /便覧10ページ/
  end

  test '区分の名前は便覧の和名で出す' do
    change_handbook do |document|
      document['categories'].find { |category| category['key'] == 'health' }['label'] = '別名の健康'
    end

    show_selected

    assert_select 'li[data-rule-id="health"]', text: /別名の健康の合計/
  end

  test '判定の途中経過は出さない' do
    show_selected

    assert_select 'body', text: /確認済み算入/, count: 0
  end

  test '編集するための部品は出ない' do
    show_selected

    assert_select 'button[onclick]', count: 0
    assert_select '[onclick], [onchange], [oninput], [onkeyup]', count: 0
    # 公開済みを見ているときに置いてよいフォームは2つだけ。選択(GET)と、複製して直すボタン(下書きを1つ作るだけで、
    # 公開済みの行は書き換えない)。PDFのアップロードは、便覧が無いときの入口で、ここには出ない。
    assert_select 'main form', count: 2
    assert_select 'main form[method=get][action=?]', requirements_path, count: 1
    assert_select 'main form[action=?]', duplicate_curriculum_path(@curriculum), count: 1
    assert_select 'main form[action=?]', curricula_path, count: 0
    assert_select 'main textarea', count: 0
    assert_select 'main select', count: 3
    assert_select 'main script', count: 0
    assert_select 'body', text: /ルールビルダー|要件を保存|ルート区分を追加|リセット/, count: 0
  end

  test '規則の型が未知の便覧でも画面は開く' do
    change_handbook do |document|
      document['rules'] << { 'id' => 'gpa', 'type' => 'gpa', 'label' => 'GPA' }
    end

    show_selected

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

    error = assert_raises(ArgumentError) { show_selected }
    assert_match(/categories の key が重複/, error.message)
  end

  test '規則が存在しない区分を指す便覧も開かない' do
    change_handbook do |document|
      document['rules'] << { 'id' => 'ghost', 'type' => 'credit_sum', 'label' => 'x', 'categories' => ['nowhere'],
                             'required_credits' => 1 }
    end

    assert_raises(ArgumentError) { show_selected }
  end

  test '入れ子の奥の読めない選択肢は、その規則の側でも見つけられる' do
    change_handbook do |document|
      document['rules'] << { 'id' => 'gpa', 'type' => 'gpa', 'label' => 'GPA' }
      document['rules'].find { |rule| rule['id'] == 'foreign_language' }['options'] << { 'type' => 'gpa' }
    end

    show_selected

    assert_equal %w[foreign_language gpa], css_select('li[data-rule-status="unknown"]').pluck('data-rule-id')
    assert_select 'li[data-rule-id="foreign_language"] div.text-red-700', text: /要確認になります.*外国語の選択経路/m
  end

  test '選択肢が空の規則は赤で出る' do
    change_handbook do |document|
      document['rules'].find { |rule| rule['id'] == 'foreign_language' }['options'] = []
    end

    show_selected

    assert_select 'li[data-rule-id="foreign_language"][data-rule-status="unknown"] .text-red-700', text: /選択肢が空です/
  end

  test '系列が混在したときの確認事項が出る' do
    show_selected

    assert_select 'li[data-rule-id="calculus"]', text: /系列が混在したとき：/
  end
end

