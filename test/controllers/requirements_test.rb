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

  # 下書きの欄の各行(上から)の { 続きのリンク, 更新日時の表示, datetime 属性 }
  def draft_rows
    css_select('[data-drafts] li').map do |row|
      { href: row.at_css('a')['href'], shown: row.at_css('time').text.strip, datetime: row.at_css('time')['datetime'] }
    end
  end

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
    # 空の値の選択肢は、選択の各欄の「選んでください」だけ(取り込みフォームの選択は、別に見る)
    assert_select 'form[method=get] select option[value=""]', count: 3
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

  test '公開済みと下書きが両方ある組み合わせでも、編集するボタンは出る。下書きは件数と続きのリンクを並べる' do
    # 識別名が違う下書きでも、同じ3つの値なら並ぶ(選択は識別名を持たない)
    # 差し替えると旧版が下書きに戻って残るので、下書きの有無でボタンを隠すと、1回直しただけで次の編集ができなくなる
    draft = create_draft(admission_year: 2024)

    show_selected

    assert_select '[data-total-credits]', text: /130/
    assert_select 'form[action=?]', duplicate_curriculum_path(@curriculum), count: 1
    assert_select '[data-drafts] h3', text: /同じ年度の下書きが1件あります/
    assert_select 'a[href=?]', curriculum_path(draft), text: /下書きの確認を続ける/
    # 作業中か旧版かは見分けられないので、作業が途中だとは言わない
    assert_select 'body', text: /作業が途中/, count: 0
  end

  test '差し替えたあとも、同じ選択に編集するボタンが残る(旧版が下書きに戻っても隠さない)' do
    post duplicate_curriculum_path(@curriculum), env: local_env
    copy = Curriculum.drafts.order(:id).last
    copy.update!(document: copy.document.deep_dup) # 直さなくても公開できる複製(科目は確認済み)
    post publish_curriculum_path(copy), params: { replace: '1' }, env: local_env
    assert_redirected_to requirements_path(selection)

    follow_redirect!

    assert_response :success
    assert_select '[data-total-credits]', text: /130/
    assert_select 'form[action=?]', duplicate_curriculum_path(copy), count: 1
    assert_select '[data-drafts] a[href=?]', curriculum_path(@curriculum)
  end

  test '下書きが複数あれば、すべて続きのリンクにする' do
    first = create_draft
    second = create_draft

    show_selected(admission_year: 2030)

    assert_select 'a[href=?]', curriculum_path(first)
    assert_select 'a[href=?]', curriculum_path(second)
  end

  # 同じ年度の下書きが何件あっても、行の見た目だけでは見分けられない(年度・コース名・ファイル名が同じ)。
  # 公開を差し替える画面で古い版を選ぶと、直した分が戻るので、新しい順に並べ、各行に自分の更新日時を出す。
  # 作った順(id)・更新の古い順とは別の並びにして、どちらの並べ方でも落ちるようにする。
  test '同じ年度の下書きは、更新の新しい順に並び、各行がそれぞれの更新日時を日本時間で出す' do
    # 日本時間の日付と UTC の日付がずれる時刻も入れる(UTC のまま出すと、日付も違ってしまう)
    middle = create_draft(admission_year: 2030, updated_at: Time.utc(2026, 11, 4, 16, 5))
    oldest = create_draft(admission_year: 2030, updated_at: Time.utc(2026, 10, 1, 0, 0))
    newest = create_draft(admission_year: 2030, updated_at: Time.utc(2026, 11, 5, 5, 32))

    show_selected(admission_year: 2030)

    rows = draft_rows
    assert_equal [newest, middle, oldest].map { |draft| curriculum_path(draft) }, rows.pluck(:href)
    assert_equal ['2026年11月5日 14:32', '2026年11月5日 01:05', '2026年10月1日 09:00'], rows.pluck(:shown)
    assert_equal [newest, middle, oldest].map { |draft| draft.updated_at.utc.iso8601 }, rows.pluck(:datetime)
  end

  test '更新日時が同じ下書きは、あとから作ったものを先に並べる' do
    stamp = Time.utc(2026, 11, 5, 5, 32)
    first = create_draft(admission_year: 2030, updated_at: stamp)
    second = create_draft(admission_year: 2030, updated_at: stamp)

    show_selected(admission_year: 2030)

    assert_equal [second, first].map { |draft| curriculum_path(draft) },
                 css_select('[data-drafts] li a').pluck('href')
  end

  test '2回続けて直して差し替えたあと、先頭の下書きは新しい方の旧版で、最初の版は最後になる' do
    # 差し替えるたびに、置き換わった公開済みが下書きに戻る。戻した時刻が、その行の更新日時になる
    original = @curriculum
    first_fix = nil
    travel_to Time.utc(2026, 11, 1, 3, 0) do
      post duplicate_curriculum_path(original), env: local_env
      first_fix = Curriculum.drafts.order(:id).last
      post publish_curriculum_path(first_fix), params: { replace: '1' }, env: local_env
    end
    travel_to Time.utc(2026, 11, 20, 3, 0) do
      post duplicate_curriculum_path(first_fix), env: local_env
      second_fix = Curriculum.drafts.order(:id).last
      post publish_curriculum_path(second_fix), params: { replace: '1' }, env: local_env
    end
    assert_equal [original.id, first_fix.id], Curriculum.drafts.order(:id).ids

    show_selected

    rows = draft_rows
    assert_equal [first_fix, original].map { |draft| curriculum_path(draft) }, rows.pluck(:href)
    assert_equal ['2026年11月20日 12:00', '2026年11月1日 12:00'], rows.pluck(:shown)
  end

  test '下書きの行は、旧版か作業中かを言い当てる印や文言を持たない' do
    create_draft(admission_year: 2024)

    show_selected

    assert_select '[data-drafts]', text: /旧版です|作業中です|古い版|新しい版|最新/, count: 0
  end

  test '便覧の無い年度を選ぶと、無いと伝え、PDFから作る導線が出る' do
    show_selected(admission_year: 2030)

    assert_response :success
    assert_select 'body', text: /この年度の便覧はまだありません/
    assert_select 'form[action=?][enctype="multipart/form-data"]', curricula_path
    assert_select '[data-total-credits]', count: 0
    assert_select 'form[action*=duplicate]', count: 0
  end

  test '取り込みのフォームは、PDFでないものを落とされたときに出す断りを、隠した状態で持っている' do
    show_selected(admission_year: 2030)

    # ドロップはファイル選択の accept を通らない。dropzone コントローラーは、この欄が無いと動かない
    assert_select 'form[action=?][data-controller~=dropzone] [data-dropzone-target=error][role=alert][hidden]',
                  curricula_path, text: /PDFファイルを選んでください/, count: 1
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
    # 空の年度は「選んでいない」で、別のテスト(指定が3つ揃っていないとき)が見ている
    ['abc', '2024abc', '20.5', '-1', '0', '10000', '99999999999999999999999', '０'].each do |year|
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

      # 下書きだけの組み合わせでも、公開済みが無いので呼ばない
      create_draft(admission_year: 2031)
      show_selected(admission_year: 2031)
      assert_response :success
      assert_select 'a[href^="/curricula/"]'
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
      assert_select 'li[data-row="health"]', text: /健康運動系.*2\s*単位.*共通教育・教養領域/m
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

  # 実物の2024年度が持つ27件の規則のうち、上のカード（章・行・小計）がすでに同じ単位数で言っている11件の credit_sum
  # を除いた16件が、便覧の並びのまま出る。
  SHOWN_2024 = %w[humanities social general_integrated general_without_natural japanese english_required
                  foreign_language calculus physics required_all required_total fusion_provider total natural_cap
                  excluded_category own_fusion].freeze
  OMITTED_2024 = %w[health general_subtotal common_total basic_total required_information required_comprehensive
                    required_research required_math required_core elective_inner elective_total].freeze

  test '判定の規則は、上のカードから読み取れないものだけが、便覧の並びのまま出る' do
    show_selected

    all_ids = @curriculum.document.fetch('rules').pluck('id')
    assert_equal all_ids - OMITTED_2024, css_select('#judgement-rules li[data-rule-id]').pluck('data-rule-id')
    assert_equal SHOWN_2024.sort, (all_ids - OMITTED_2024).sort
    assert_select 'li[data-rule-id="natural_cap"]', text: /自然系.*2\s*単位/
    assert_select 'li[data-rule-id="own_fusion"]', text: /知能/
  end

  test '2025年度の規則は、カードが同じ単位数で言っている8件を省く' do
    show_selected(admission_year: 2025)

    document = Curriculum.published.find_by!(slug: 'intelligent_informatics', admission_year: 2025).document
    all_ids = document.fetch('rules').pluck('id')
    assert_equal 19, all_ids.size
    shown = css_select('#judgement-rules li[data-rule-id]').pluck('data-rule-id')
    assert_equal %w[rule_academic_skills rule_health_sports rule_liberal_arts rule_ge_total rule_pe_required
                    rule_pe_elective rule_pe_elective_course rule_pe_total], all_ids - shown
    assert_equal 11, shown.size
    # 名指しされない卒業要件の合計は残る
    assert_select '#judgement-rules li[data-rule-id=?]', 'rule_total'
    # 区分の下限、系列の選択、外国語の経路、算入しない規則は残る
    assert_select '#judgement-rules li[data-rule-id=?]', 'rule_humanities_min'
    assert_select '#judgement-rules li[data-rule-id=?]', 'rule_calculus_path'
    assert_select '#judgement-rules li[data-rule-id=?]', 'rule_foreign_lang'
    assert_select '#judgement-rules li[data-rule-type=exclude]', count: 4
  end

  test '上のカードと同じことを言うだけの規則は、規則の節に出さない' do
    show_selected

    # 「健康運動系の合計 2単位以上」は上の行に出ているので、規則の節には出さない
    assert_select '#judgement-rules', text: /健康運動系の合計/, count: 0
    assert_select '#judgement-rules li[data-rule-id=health]', count: 0
    # 系列の選択・算入上限・算入しない規則は、カードからは読み取れないので残す
    assert_select '#judgement-rules', text: /微分積分学/
    assert_select '#judgement-rules', text: /自然系は卒業算入の上限/
    assert_select '#judgement-rules', text: /外国語の選択経路/
    # 章の見出しと同じことを言う合計は出さない。必修すべては、見出しが言えない「すべて修得」を言うので残る
    assert_select '#judgement-rules li[data-rule-id=common_total]', count: 0
    assert_select '#judgement-rules li[data-rule-id=elective_total]', count: 0
    assert_select '#judgement-rules li[data-rule-id=required_all]', text: /すべて修得/
    assert_select '#judgement-rules li[data-rule-id=total]', text: /備考/
  end

  test '省いた件数を、規則の節で伝える(黙って消さない)' do
    show_selected

    assert_select '#judgement-rules [data-omitted-rules]', text: /11件/
  end

  test '省くかどうかは便覧の中身で決まる。健康運動の行を消せば、健康運動の規則が出る' do
    change_handbook do |document|
      document['display']['groups'].each { |group| group['rows'].reject! { |row| row['id'] == 'health' } }
    end

    show_selected

    assert_select '#judgement-rules li[data-rule-id=health]', count: 1
    assert_select '#judgement-rules [data-omitted-rules]', text: /10件/
  end

  test '規則には出典のページを添える' do
    show_selected

    assert_select 'li[data-rule-id="humanities"]', text: /便覧10ページ/
  end

  test '区分の名前は便覧の和名で出す' do
    change_handbook do |document|
      document['categories'].find { |category| category['key'] == 'humanities' }['label'] = '別名の人文'
    end

    show_selected

    assert_select 'li[data-rule-id="humanities"]', text: /別名の人文の合計/
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

  # ---- 科目表 ----

  test '科目表が区分ごとに出る' do
    show_selected

    assert_select 'details summary', text: /人文系/
    # 実物の2024年度に「人101」は無い。人文系の先頭は「人01」（brief の例は実物と合っていなかった）
    assert_select '[data-course-number]', text: '人01', count: 1
    assert_select 'details[data-course-category=humanities] [data-course-number]', text: '人01', count: 1
  end

  test '科目表の区分は、便覧の和名で出し、生のキーは出さない' do
    show_selected

    assert_select '#course-table details[data-course-category=required_core] summary', text: /知能情報コア（必修）/
    assert_select '#course-table summary', text: /required_core|elective_math/, count: 0
  end

  test '科目表は区分ごとに畳んである。畳んでも行は DOM に残り、ブラウザの検索で届く' do
    show_selected

    document_courses = @curriculum.document.fetch('courses')
    assert_equal 484, document_courses.size
    assert_select '#course-table details[open]', count: 0
    assert_select '#course-table tr[data-course]', count: 484
    # 遅延読み込みにしない。行は初めから HTML に入っている
    assert_select '#course-table turbo-frame, #course-table [src], #course-table [loading]', count: 0
    # 区分の科目数は、便覧の科目を数えたものと一致する
    @curriculum.document.fetch('categories').each do |category|
      count = document_courses.count { |course| course['category'] == category['key'] }
      selector = "#course-table details[data-course-category=#{category['key']}]"
      if count.zero?
        assert_select selector, count: 0
      else
        assert_select "#{selector} tr[data-course]", count: count
      end
    end
  end

  test '科目の行に、科目番号・科目名・単位数・必修かどうかが出る' do
    show_selected

    row = css_select('#course-table tr[data-course]').find { |tr| tr.at_css('[data-course-number]')&.text == '知能101' }
    assert_not_nil row
    assert_equal(%w[知能101 プログラミング演習Ⅰ 1 必修], row.css('td').map { |cell| cell.text.squish })
    # 必修でない科目は「必修」と出さない
    optional = @curriculum.document.fetch('courses').find { |course| course['required'] != true }
    optional_row = css_select('#course-table tr[data-course]').find do |tr|
      tr.at_css('[data-course-number]')&.text == optional['number']
    end
    assert_not_nil optional_row
    assert_no_match(/必修/, optional_row.text)
    assert_equal 4, optional_row.css('td').size
  end

  test '科目表の節は、この画面から編集できる部品を持たない' do
    show_selected

    assert_select '#course-table form, #course-table input, #course-table button, #course-table a', count: 0
  end

  test '2025年度の科目表は99件' do
    show_selected(admission_year: 2025)

    assert_select '#course-table tr[data-course]', count: 99
    assert_select '#course-table details summary', text: /工学共通（必修）/
  end

  test '科目表の区分の見出しと科目数は、便覧を書き換えればその通りに変わる' do
    change_handbook do |document|
      document['categories'].find { |category| category['key'] == 'humanities' }['label'] = '別名の人文'
    end

    show_selected

    assert_select '#course-table details[data-course-category=humanities] summary', text: /別名の人文/
    assert_select '#course-table summary', text: /人文系/, count: 0
  end

  # ---- カードの見た目をダッシュボードに揃える ----

  test '章の行は、ダッシュボードの区分カードと同じ殻・余白・数字の大きさで組む' do
    show_selected

    # ダッシュボード(dashboard/show)のカードと同じ class。見た目が別のアプリに見えないように
    assert_select 'li[data-row="health"].rounded-2xl.border.border-slate-200.bg-white.shadow-xs'
    assert_select 'li[data-row="health"] > div.grid.p-5.sm\\:p-6'
    assert_select 'li[data-row="health"] h4.text-xs.font-semibold.text-slate-500', text: /健康運動系/
    assert_select 'li[data-row="health"] [data-row-credits] span.text-3xl.font-extrabold.tabular-nums', text: '2'
    assert_select 'li[data-row="health"] [data-row-credits] span.text-sm.font-medium.text-slate-500', text: /単位/
  end

  test 'ダッシュボードにある、学生の進み具合に結びついた部品は出さない' do
    show_selected

    assert_select 'main .demo-status', count: 0
    assert_select 'main [role=progressbar], main [data-status], main [data-actual-status]', count: 0
    assert_select 'main turbo-frame', count: 0
  end
end

