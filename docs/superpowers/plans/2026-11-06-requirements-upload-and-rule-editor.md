# 取り込みフォームの見直しと規則エディタのJSON廃止 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 便覧PDFの取り込みフォームを「対象を選ぶ」カードと同じ見た目のプルダウンにし、学部・学科・コースを既存DB（Faculty/Department/Program）から選ばせる。入学年度の範囲を2016年度〜来年度に揃え、表示を「2024年」のような年だけにする。共通教育は科目番号のパターンで判定できるようにして、取り込みの科目表には載せない。要件表の確認画面を、`main` にある「卒業要件ルールビルダー」(完全に静的なモックアップ)と同じ見た目の、章・行・規則を入れ子にしたツリーに作り直し、JSON欄を使わず画面の入力だけで編集できるようにする（one_of_paths・any_of・all_of を含む）。見た目だけを真似るのではなく、本物の `Curriculum#document`(display・rules)を下敷きに動かす。

**Architecture:** 学部・学科・コースの選択肢は `Faculty`/`Department`/`Program`（既存のAR）から作る。`Curriculum#department_name` は今までどおり「学科・コース名」を1つの文字列で持つ（スキーマは変えない）。画面には学科とコースを別のプルダウンで出し、コントローラが選ばれた学科名とコース名を1つの文字列に結んでから `department_name` に渡す（人が手で「工学科 知能情報コース」と打っていたのと同じ値になる。コースの無い学科は学科名だけになる、今までと同じ）。共通教育の判定は、`GraduationAssessment::Catalogue` に「科目表に無い科目でも、区分の `number_patterns` に科目番号が一致すれば、その区分として数える」という推定経路を1つ足す（既存の科目表と役割の仕組みには触れない）。要件表の確認画面は、章(display.groups)・行(display.rows)を、`<details>` で畳んだ編集欄ではなく常時編集できる入れ子のツリーにし、行が指す規則(check_id/check_ids)のうち one_of_paths・any_of・all_of を、行の下に入れ子のボックスとして出す(それ以外の規則はバッジ無しで単位数だけ)。経路・条件の編集は、既存の `rule_fields` と同じ「欄ごとに直せる」考え方の上に、繰り返し行（経路・条件）を増減できるUIで置き換える。繰り返し行の増減は、新しい汎用の Stimulus コントローラ（配列パラメータの `[]` 記法をそのまま使い、添字の付け替えをしない）で行う。フォーム・保存の仕組み(1つの `requirements_form`、`RequirementsEdit`、`revision` による競合検出)は変えない。

**Tech Stack:** Rails 8.1 / Hotwire(Stimulus) / Tailwind（既存どおり。gemを足さない）

**Spec:** `docs/superpowers/specs/2026-10-29-curriculum-import-design.md`（便覧取り込みの元の設計）。本計画は、その設計が「今回は作らない」と明言した共通教育の重複解消と、JSON直書きに残していた規則編集を実装する追加計画。

## Global Constraints

- gemを足さない。ジョブ基盤を入れない。
- `test/fixtures/files/graduation_golden_2024.json` は一切変えない。判定が動いていない証拠なので、動いたら退行として報告する。
- コメントは日本語で、なぜそうしたかを書く。周りの密度に合わせる。
- テストは1ファイルずつ走らせる。並列で2つ走らせるとコンテナ内のテストDBが壊れる。触っていないファイルが落ちたら、単独で回し直してから信じる。
- 画面は既存の `LocalAccessOnly` の守りを外さない。認証は範囲外。
- 学部・学科のマスタ名は `db/seeds/academic_organizations.rb` の既存の表記（例:「工学部」「工学科」）に揃える。新しく作る値は、確からしい根拠（既存の `Curriculum` の実データ）があるものだけにする。琉球大学の実際の学科構成を知らないまま推測で作らない。
- `Program`（コース）は、今回 `工学科 → 知能情報コース` の1件だけをseedする。他学部・他学科にコースがあるかどうかは分からないので作らない（コースが無い学科は、画面でコースの欄を出さない）。

## Review Focus

- 学科とコースのプルダウンを結合した `department_name` が、既存の2件の `Curriculum`（2024・2025年度、"工学科 知能情報コース"）と文字どおり一致し、同じ `slug` を指し続けるか（学生の判定が別の便覧に切り替わらないか）。
- 入力欄に無い学部・コースを初めて登録する「その他」の経路が、Program表に無い学科を選んだときも塞がらないか。
- 共通教育の `number_patterns` が、便覧ごとに作った区分キーと食い違ったまま公開されないか（読み込み時に例外にする）。
- `one_of_paths`・`any_of`・`all_of` を画面の入力だけで作ったとき、JSONで直接書いていた入れ子（`all_of` の中の `credit_sum` など）が1階層で終わらず、2階層目まで保存・再表示できるか。
- 年度の範囲を2016年度からに変えたとき、既存の2024・2025年度の便覧（下限・上限の外ではない）の選択肢・バリデーションが壊れないか。

---

### Task 1: 取り込みフォームと対象選択を、Faculty/Department/Programから作る

**Files:**
- Create: `db/seeds/programs.rb`
- Modify: `db/seeds.rb`（`programs.rb` を読む1行を足す。`AcademicOrganizations.load!` の直後）、`app/controllers/requirements_controller.rb`（`load_options`・`@selection`・`selection_complete?`・`resolve_selection`）、`app/controllers/concerns/curriculum_upload_params.rb`（`course_name`・`course_name_other` を許可し、`curriculum_attributes` で `department_name` に結ぶ）、`app/controllers/curricula_controller.rb`（`upload_error` に「コースがある学科なのにコース未選択」の拒みを足す。`FIELD_LABELS` は変えない）
- Test: `test/controllers/requirements_controller_test.rb`、`test/controllers/curricula_test.rb`

**Interfaces:**
- Consumes: 既存の `Faculty`/`Department`(has_many :departments)/`Program`(belongs_to :department)。`Curriculum#department_name`(既存のまま、スキーマは変えない)
- Produces: `RequirementsController#load_options` が `@faculty_options`(Array<String>, `Faculty.order(:name).pluck(:name)`)、`@department_options`(Hash<faculty_name, Array<String>>, `Department` を学部ごとに)、`@course_options`(Hash<department_name, Array<String>>, `Program` を学科ごとに)、`@year_options`(既存どおり `Curriculum` の実データから。このタスクでは変えない)を作る。`@selection` に `:course` を追加。`selection_complete?` は「学部・学科・年度は常に必須、コースは `@course_options[@selection[:department]]` が空でないときだけ必須」で判定する。`CurriculumUploadParams#curriculum_attributes[:department_name]` は `[学科名, コース名].compact_blank.join(' ')`(コースが無ければ学科名だけ。人が手で「工学科 知能情報コース」と打っていたのと同じ値になる)。

**ルール:** `Curriculum` のスキーマ・`slug_for_program`・`PublishedDocument`・`Publication`・`Duplicate` は一切変えない(Task1実行中に見つけたルールの経緯は ledger の `Task 1: Ruling` を参照。`department_name` を分けると約30件の既存テストと公開周りのコードが割れると分かったため、結合はコントローラ層だけで行う)。

**選択肢の作り方:** 学部・学科・コースは、既存の `Curriculum` の実データからではなく、マスタ(`Faculty`/`Department`/`Program`)から作る(まだ便覧の無い学部・学科・コースも選べるようにする)。`@department_options`・`@course_options` は `requirements_helper.rb` の既存の `grouped_options_for_select` 呼び出しがそのまま使える形(`Hash<親の名前, Array<子の名前>>`)にする(既存の `@department_options` と同じ形)。

**「その他（新しく登録する）」:** 学部・学科（既存どおり）に加えてコースにも効く。学科にProgramが1件も無い学科を選んだときは、コースの欄自体を出さない(Task 2 のJSで隠す)。

**`resolve_selection`・選択時のクエリ一致:** `/requirements` の選択(`faculty`/`department`/`course`/`admission_year`)で便覧を探すときは、`Curriculum.where(faculty_name: ..., department_name: [@selection[:department], @selection[:course]].compact_blank.join(' '), admission_year: ...)` のように、学科名とコース名を結んだ文字列で既存どおり照合する。

**取り込みの拒み(バックエンドの安全策):** HTMLの `required` だけに頼らず、`CurriculaController#upload_error` に、選んだ学科に `Program` があるのに `course_name` が空のときの拒みを足す(`"コースを選んでください。"` のような文。`curriculum.valid?(:upload)` の失敗より前に見る)。JSが効かない・迂回された送信でも、学科名だけの `department_name` で違う課程を指してしまわないようにする。

- [x] **Step 1: 失敗するテストを書く**

```ruby
# test/controllers/requirements_controller_test.rb
test '学部の選択肢はFacultyテーブルから作る(便覧の有無を問わない)' do
  Faculty.find_or_create_by!(name: '理学部')
  get requirements_path, env: local_env

  assert_select 'select[name=faculty] option', text: '理学部'
end

test 'コースの選択肢はProgramテーブルから作る' do
  get requirements_path, env: local_env

  assert_select 'select[name=course] option', text: '知能情報コース'
end
```

```ruby
# test/controllers/curricula_test.rb
test 'コースがある学科なのにコースを選ばずに送ると断る(department_nameが学科名だけにならない)' do
  post curricula_path, params: upload_params(department_name: '工学科', course_name: nil), env: ENV_LOCAL

  assert_redirected_to requirements_path(faculty: '工学部', department: '工学科', admission_year: 2026)
  follow_redirect!
  assert_match(/コースを選んでください/, flash[:alert])
  assert_equal 0, Curriculum.where(department_name: '工学科').count
end
```

- [x] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/controllers/requirements_controller_test.rb test/controllers/curricula_test.rb`
Expected: FAIL

- [x] **Step 3: 作る**

`db/seeds/programs.rb` に `Program.find_or_create_by!(name: '知能情報コース', department: Department.find_by!(name: '工学科'))` を書く。`load_options` を `Faculty`/`Department`/`Program` から作るように書き直す。`CurriculumUploadParams` に `course_name`/`course_name_other` を足し、`curriculum_attributes[:department_name]` を結合で作る。`upload_error` にコース必須の拒みを足す。

- [x] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [x] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 取り込みフォームと対象選択をFaculty/Department/Programから作る"
```

---

### Task 2: 取り込みフォームの見た目と年度の範囲・表示を直す

**Files:**
- Modify: `app/views/requirements/_selector.html.erb`、`app/views/requirements/_upload.html.erb`、`app/views/requirements/_empty.html.erb`（表示に `@selection[:course]` を足す）、`app/helpers/requirements_helper.rb`（`upload_form_defaults`・`UploadDefaults` にコースの初期値を足す）、`app/javascript/controllers/program_fields_controller.js`、`app/models/curriculum.rb`（`UPLOAD_MIN_YEAR`・`upload_year_range`・`upload_year_choices`・`UPLOAD_YEARS_BACK` を削除）
- Test: `test/models/curriculum_test.rb`、`test/helpers/requirements_helper_test.rb`、`test/controllers/curricula_test.rb`

**Interfaces:**
- Consumes: Task 1 の `@course_options`・`@selection[:course]`
- Produces: `Curriculum.upload_year_range`(変更: `2016..(今年+1)`)。`Curriculum.upload_year_choices`(引数・戻り値は変えない。範囲だけ変わる)。`upload_form_defaults(selection, faculty_options, department_options, course_options)`(引数4つ。戻り値の `UploadDefaults` に `course`/`course_other` を足す)。

**年度:** `UPLOAD_MIN_YEAR` を `2016`(学生便覧が載っている最古の年度)に変える。上限を「今年+2」から「今年+1」(来年度まで)に変える。`UPLOAD_YEARS_BACK`(今年-10で下限を作っていた仕組み)は削除し、`upload_year_choices` は常に `upload_year_range` をそのまま使う(2016年度から今年+1年度まで、`including` は範囲内なら今のまま足す)。`Time.zone.today.year` を毎回呼ぶ既存の作りはそのまま保つので、年度が変われば次に開いたときに自動で動く(追加の対応は不要。テストでこれを固定する)。

**表示:** 年度の選択肢の文字列を `"#{year}年度入学"` から `"#{year}年"` に変える。`_selector.html.erb` と `_upload.html.erb` の両方。

**既定表示:** 4つの欄（学部・学科・コース・年度）の空の選択肢の文字を `選んでください` から `---------` に変える(`include_blank: '---------'`)。`_upload.html.erb` の `admission_year` は今は `include_blank: false`(常に今年を選ぶ)だが、他の欄と揃えて `---------` を選べるようにし、選ばなければ送信時にエラーにする(`required: true` を足す。空のまま送ると `curriculum_attributes[:admission_year]` が空文字になり、既存の `upload_error` の検証がそのまま拒む → 既存のエラー文言を使う。新しいテストは不要、既存の「年度が無いと断る」テストが通ることで確かめる)。

**レイアウト:** `_upload.html.erb` の `grid-cols-2`(空の `div` で埋めていた不揎な並び)を、`_selector.html.erb` と同じ `grid gap-4 sm:grid-cols-4`(学部・学科・コース・年度の4列、空の `div` を使わない)に変える。「その他」の自由入力欄(新しい学部名・新しい学科名・新しいコース名)は、既存どおりその下に3列(`sm:grid-cols-3`)で並べる。

- [x] **Step 1: 失敗するテストを書く**

```ruby
# test/models/curriculum_test.rb
test 'アップロードできる年度は2016年度から来年度まで' do
  range = Curriculum.upload_year_range

  assert_equal 2016, range.begin
  assert_equal Time.zone.today.year + 1, range.end
end
```

- [x] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/models/curriculum_test.rb`
Expected: FAIL（現状は2000年度〜今年+2年度）

- [x] **Step 3: 作る**

上の仕様のとおりに `curriculum.rb` の定数・メソッドと、3つのビューを直す。`program_fields_controller.js` の `filterDepartments` と同じ考え方で、学科→コースの絞り込みを足す(`courseTarget`・`newCourseTarget` を増やし、`filterCourses(newDepartment)` を `filterDepartments` と並べて書く。コースが1件も無い学科を選んだときは、コースの `<label>` 全体を隠し、`required` も外す)。

- [x] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [x] **Step 5: 実際に画面で通す**

Run: 開発環境で `/requirements` を開き、学部に「工学部」、学科に「工学科」を選ぶとコースに「知能情報コース」が出ること、理学部など他学部を選ぶとコースの欄が消えること、年度が2016年から来年まで一覧でき「2024年」のように出ること、未選択の欄が「---------」であることを確かめる。
Expected: 上のとおりに動く。

- [x] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: 取り込みフォームを対象選択カードと同じ見た目にし、年度の範囲と表示を直す"
```

---

### Task 3: 区分に科目番号パターンを持たせ、判定が科目表に無い科目も数えられるようにする

**Files:**
- Modify: `app/services/graduation_assessment/catalogue.rb`（`pattern_category_for`・`validate_categories` を拡張）、`app/services/graduation_assessment/entry_normalizer.rb`（`normalize`・`pattern_course`）
- Test: `test/services/graduation_assessment/catalogue_test.rb`、`test/services/graduation_assessment/entry_normalizer_test.rb`(無ければ `graduation_assessment_test.rb` に足す)

**Interfaces:**
- Consumes: なし(既存の `CourseNumber.prefix`/`.hundreds` をそのまま使う)
- Produces: `categories` の要素が持てる任意の `number_patterns`(Array<String>)。`Catalogue#pattern_category_for(number)`(戻り値: 区分キーの文字列 or nil)。`EntryNormalizer` は、`@catalogue.find(key)` が nil でも `pattern_category_for` が当たれば、科目表に無い科目として数える。

**パターンの書式:** `CourseNumber.hundreds(number)`(例: `"外1"`)と `CourseNumber.prefix(number)`(例: `"外"`)のどちらかと文字列一致する値を `number_patterns` に書く(百の位まで書けば、同じ接頭辞の別区分と区別できる。2024年度の実データでの値は、Task 4 で便覧に書く)。`pattern_category_for` は、まず `hundreds` で当たる区分を探し、無ければ `prefix` で探す(`CategoryInference#decide` と同じ優先順位)。

**検証:** 同じパターン文字列を2つ以上の区分が持てば、読み込み時に例外にする(`validate_categories` に追記。「どの区分か決められない」まま判定が通ると、どちらかに黒の数字を出す)。

**EntryNormalizer:** `normalize(entries, course)` の `course` が nil のとき、今まで即座に `unknown` にしていたのを、`pattern_course(entries)` を試すように変える。`pattern_course` は `entries.first[:key]`(= 科目番号)を `@catalogue.pattern_category_for` に渡し、当たれば `{ 'key' => number, 'number' => number, 'name' => entries.first[:name], 'category' => category, 'source_page' => "科目番号のパターンから推定（科目表には未掲載）" }` を返す。当たらなければ nil(今までどおり `unknown`)。この合成した科目は `'required'`/`'roles'`/`'requires_approval'` を持たない(= 必修でも承認必須でもない扱い。共通教育の個々の必修科目は Task 4 で科目表に残す)。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# test/services/graduation_assessment/catalogue_test.rb
test 'pattern_category_for は百の位を優先し、無ければ接頭辞で当てる' do
  catalogue = Catalogue.new(document_with(categories: [
    { 'key' => 'english', 'label' => '英語', 'number_patterns' => ['外1'] },
    { 'key' => 'foreign_language', 'label' => '外国語', 'number_patterns' => %w[外2 外3] },
    { 'key' => 'health', 'label' => '健康', 'number_patterns' => ['健'] }
  ]))

  assert_equal 'english', catalogue.pattern_category_for('外101')
  assert_equal 'foreign_language', catalogue.pattern_category_for('外201')
  assert_equal 'health', catalogue.pattern_category_for('健01')
  assert_nil catalogue.pattern_category_for('知能101')
end

test '同じパターンを2つの区分が持つ便覧は読み込めない' do
  assert_raises(ArgumentError) do
    Catalogue.new(document_with(categories: [
      { 'key' => 'a', 'label' => 'A', 'number_patterns' => ['外1'] },
      { 'key' => 'b', 'label' => 'B', 'number_patterns' => ['外1'] }
    ]))
  end
end
```

```ruby
# test/services/graduation_assessment_test.rb (既存ファイルに足す)
test '科目表に無い科目も、番号のパターンに一致すれば区分として数える' do
  curriculum = base_curriculum.deep_merge(
    'categories' => [{ 'key' => 'health', 'label' => '健康', 'number_patterns' => ['健'], 'counts_toward_total' => true }],
    'rules' => [{ 'id' => 'health', 'type' => 'credit_sum', 'categories' => ['health'], 'required_credits' => 2 }]
  )
  result = GraduationAssessment.new(curriculum: curriculum).call(
    completed: [{ key: '健01', credits: 2, approved: nil, name: '健康科学' }]
  )

  check = result.actual.checks.find { |c| c.id == 'health' }
  assert_equal :satisfied, check.status
  assert_equal 2, check.counted_credits
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment/catalogue_test.rb test/services/graduation_assessment_test.rb`
Expected: FAIL

- [ ] **Step 3: 作る**

上の Interfaces のとおりに `Catalogue#pattern_category_for`・検証、`EntryNormalizer#pattern_course` を実装する。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS。`graduation_assessment_golden_test.rb`(2024年度の実データでの判定の固定テスト)が無傷であることも確かめる(この時点ではまだ便覧に `number_patterns` を足していないので、挙動は変わらないはず)。

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 区分に科目番号パターンを持たせ、科目表に無い科目も判定で数えられるようにする"
```

---

### Task 4: 共通教育を科目表から外し、番号パターンで判定させる

**Files:**
- Modify: `config/curricula/intelligent_informatics/2024.json`、`config/curricula/intelligent_informatics/2025.json`
- Modify: `app/services/curriculum_import/category_inference.rb`（コメントのみ。実装は変えない）
- Test: `test/services/demo_data_test.rb`、`test/services/graduation_assessment_golden_test.rb`、`test/fixtures/files/graduation_golden_2024.json`

**Interfaces:**
- Consumes: Task 3 の `number_patterns`
- Produces: なし(データの変更のみ)

**残す科目(番号で判定できない):** 役割(`roles`)を持つ科目(`japanese_expression`・`university_english`・`english_reading_intermediate`)は、個々の科目を指す規則(`one_of_paths`)があるので科目表に残す。`basic`・`required_*`・`advanced`・`related`・`fusion`・`free` の各区分(知能情報コースの専門科目)は、番号だけでは区分を決め切れない(便覧の但し書きに依存する)ので、この計画では触らない。

**科目表から外す科目・足すパターン:** `health`・`humanities`・`social`・`natural`・`integrated`・`career`・`regional`・`japanese`・`english`・`foreign_language` の各区分から、上の「残す科目」を除いた全科目を `courses` 配列から削除する。削除した科目の実際の番号帯から、各区分の `number_patterns` を作る(2024年度のデータを集計して書く。例: `health: ["健"]`, `english: ["外1"]`, `foreign_language: ["外2","外3","外4","外5","外6","外7"]` ほか)。2024年度と2025年度で科目番号の割り方が違えば、年度ごとに別の値を書く(共有しない。揃っていなければ揃える前提を置かない)。

`graduation_golden_2024.json`(2024年度の実データでの判定結果の固定フィクスチャ)は、科目表を変えても判定結果そのものは変わらない想定(番号パターンが読み取りと同じ区分を指すように作るため)。変わったら、便覧の書き方(番号パターンの範囲)が実データと食い違っている印なので、フィクスチャ側を直さずパターンを見直す。

- [ ] **Step 1: 失敗するテストを書く**

既存の `test/services/graduation_assessment_golden_test.rb` と `test/services/demo_data_test.rb` をまず動かし、今の時点でPASSすることを確かめる(これが「変える前の基準」になる。新しいテストはこのタスクでは足さない。データの変更が既存のテストを壊さないことを確かめるタスク)。

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment_golden_test.rb test/services/demo_data_test.rb`
Expected: PASS(変更前)。この結果をメモしておく。

- [ ] **Step 3: 作る**

上の仕様のとおりに2つのJSONを直す。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS(Step 2 と同じ結果)。`git diff config/curricula/` で、削除した科目数と `number_patterns` の追加だけが差分であることを確かめる。

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "fix: 共通教育を科目表から外し、科目番号パターンで判定させる"
```

---

### Task 5: 繰り返し行を増減する汎用のStimulusコントローラ

**Files:**
- Create: `app/javascript/controllers/repeater_controller.js`
- Test: なし(Stimulusの単体テストはこのプロジェクトに無い。Task 6・8のシステム的な確認に委ねる)

**Interfaces:**
- Consumes: なし
- Produces: `data-controller="repeater"` な要素の下に、`<template data-repeater-target="template">` と `data-repeater-target="list"` を置き、`data-action="click->repeater#add"` の足すボタンと、各行に `data-action="click->repeater#remove"` の消すボタンを置けば動く。

**仕組み:** `add` は `template` の内容を複製して `list` の最後に足す。複製した行の `name`/`id`/`for` 属性に含む `__INDEX__` という文字列(テンプレート側に書いておく印)を、新しい一意な値(`crypto.randomUUID()` があれば使い、無ければ `Date.now()+連番`)に置き換える(配列パラメータは `[]` のまま使うので、添字が連番である必要は無い。衝突しないことだけが要る)。`remove` はクリックされたボタンの最も近い `[data-repeater-target="row"]` をDOMから消すだけ(送信されるパラメータから自然に消える)。

- [ ] **Step 1: 書く**

`program_fields_controller.js` と同じ書き方(日本語コメント、`static targets`)で実装する。

- [ ] **Step 2: コミット**

```bash
git add -A
git commit -m "feat: 繰り返し行を増減する汎用のStimulusコントローラを足す"
```

---

### Task 6: 章・行を、対応する規則を入れ子にしたツリー表示にし、インライン編集にする

**Files:**
- Modify: `app/views/curricula/_requirements_table.html.erb`（章・行を常時編集可能なツリーに作り直す。`<details>` での開閉をやめる）、`app/views/curricula/_requirements_row.html.erb`（同上。行の下に、対応する規則を入れ子で出す）、`app/helpers/requirements_review_helper.rb`（行・章から対応する規則を引く `rules_for`、規則の種類を「AND/OR/単独」で表すラベルを返す `rule_logic_label` を足す）
- Test: `test/helpers/requirements_review_helper_test.rb`、`test/controllers/curricula_requirements_review_test.rb`

**Interfaces:**
- Consumes: 既存の `review.groups`・`review.rows_of(group)`・`review.rule_ids`・`RequirementsReviewHelper::FIELD_NAMES` 等（変えない）
- Produces: `RequirementsReviewHelper#rules_for(ids, review)`(`Array<rule Hash>`。`ids` は `check_id`/`check_ids` の値。見つからない id は結果に含めない)。`RequirementsReviewHelper#rule_logic_label(rule)`(`'AND'`・`'OR'`・`nil`。`one_of_paths`・`any_of` は `'OR'`、`all_of` は `'AND'`、それ以外(credit_sum等)は `nil`)。

**見た目の方針(main の `app/views/requirements/show.html.erb` の「卒業要件ルールビルダー」モックに寄せる。ただし見た目だけを真似るのではなく、本物の `display.groups`/`display.rows`/`rules` を下敷きにする)：**
- 章(group)は角丸の枠(`rounded-xl border border-slate-200 bg-slate-50/60 p-4`)。タイトルと必要単位は、モックと同じく常時編集できる `<input>`(今までの「この章を直す」という `<details>` の開閉をやめる。直す対象が最初から見えている状態にする)。
- 行(row)は章の枠の中に入れ子(`ml-4 pl-4 border-l-2`)。名前と必要単位も常時編集できる `<input>`。
- 行が `check_ids` で指す規則を `rules_for` で引き、`rule_logic_label` が `'OR'`/`'AND'` を返す規則(one_of_paths・any_of・all_of)だけ、行の下にモックの「入れ子(OR条件グループ)」と同じ見た目(琥珀色の枠)で、バッジ(OR/AND)と規則の `rule_summary` の文面を出す(経路・条件そのものの編集は Task 7)。`credit_sum`・`all_required`・`grouped_max`・`cap`・`exclude` など、バッジを持たない規則は行の右側に単位数だけ出す(モックの1〜3番目の章と同じ、バッジ無しの行)。
- 「この章/行を消す」・区分のチェック・副題・`required_label` など、今の `<details>` の中にあった残りの欄は、常時編集のすぐ下に小さく(`text-xs`)並べる(無くさない。隠すのをやめるだけ)。
- 保存ボタン・`revision`・フォーム自体(`requirements_form`)は変えない(1つの保存ボタンで章・行・規則をまとめて送る、という今の作りをそのまま使う)。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# test/helpers/requirements_review_helper_test.rb
test 'rules_for は check_ids の id から規則を引く。見つからないidは含めない' do
  review = build_review(rules: [{ 'id' => 'a', 'type' => 'credit_sum' }])

  assert_equal [{ 'id' => 'a', 'type' => 'credit_sum' }], rules_for(%w[a missing], review)
end

test 'rule_logic_label は one_of_paths・any_ofをOR、all_ofをAND、それ以外はnilにする' do
  assert_equal 'OR', rule_logic_label({ 'type' => 'one_of_paths' })
  assert_equal 'OR', rule_logic_label({ 'type' => 'any_of' })
  assert_equal 'AND', rule_logic_label({ 'type' => 'all_of' })
  assert_nil rule_logic_label({ 'type' => 'credit_sum' })
end
```

```ruby
# test/controllers/curricula_requirements_review_test.rb (既存ファイルに追記)
test '章・行の名前と必要単位は、開かなくても直せる(常時表示の入力欄)' do
  get curriculum_path(draft_with_requirements), env: ENV_LOCAL

  assert_select '#requirements_table details', count: 0
  assert_select '#requirements_table input[type=text]', minimum: 1
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/helpers/requirements_review_helper_test.rb test/controllers/curricula_requirements_review_test.rb`
Expected: FAIL

- [ ] **Step 3: 作る**

上の Interfaces・見た目の方針のとおりに実装する。`_requirements_row.html.erb`・`_requirements_table.html.erb` の既存の欄(name・required_credits・check_ids 等)の**パラメータ名は1つも変えない**(`RequirementsEdit`・`DisplayEditing` は触らない。見た目だけを作り直す)。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: 実際に画面で通す**

Run: 開発環境で下書きの要件表を開き、章・行のタイトルや必要単位を(開かずに)直して保存できること、one_of_pathsが当たる行の下にOR/ANDのバッジ付きで規則の文面が出ることを確かめる。
Expected: 上のとおりに動く。

- [ ] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: 章・行を規則を入れ子にしたツリー表示にし、インライン編集にする"
```

---

### Task 7: one_of_paths・any_of・all_ofの経路・条件を、入れ子のボックスの中でJSONなしに編集できるようにする

**Files:**
- Modify: `app/services/curriculum_import/requirements_edit.rb`（`RULE_FIELD_KINDS` に `paths: :paths`・`list: :conditions` を足す）、`app/services/curriculum_import/requirements_edit/coercion.rb`（`coerce`・`same?`・`baseline` に `:paths`・`:conditions` を足す。`:conditions` は型ごとに `credit_sum`/`grouped_max`/(any_ofのときのみ)`all_of` を1条件ずつ組み立て直す。`all_of` の中にさらに `all_of`/`any_of` が来たら、その条件ごと捨てて `error` を積む）、`app/helpers/requirements_review_helper.rb`（`role_checks`。選択肢は `review.known_roles`）
- Create: `app/views/curricula/_requirements_rule_paths.html.erb`（one_of_pathsの経路の repeater）、`app/views/curricula/_requirements_rule_condition.html.erb`（any_of/all_ofの1条件ぶんの型選択＋欄。`all_of` を選んだときは自分自身をもう1段だけ再帰的に呼ぶ）
- Modify: `app/views/curricula/_requirements_row.html.erb`（Task 6 で出した入れ子のボックスの中に、`_requirements_rule_paths`/`_requirements_rule_condition` の repeater を差し込む）
- Test: `test/services/curriculum_import/requirements_edit/rule_editing_test.rb`

**Interfaces:**
- Consumes: Task 5 の `repeater` コントローラ
- Produces: `Coercion#coerce(value, :paths, name)` が `rules[N][paths][M][roles][]` の形(経路ごとに添字M、経路内の役割は `[]`)を `Array<Array<String>>` にする。空の経路(roles が空)は捨てる。`Coercion#coerce(value, :conditions, name)` が `rules[N][options または conditions][M][type]` ほかの形を `Array<Hash>` にする(1条件が `{'type'=>..,...}`。id・labelは持たない)。

**パラメータの形・経路の扱い・条件オブジェクトの組み方:** 元のTask 6・7(現在は Task 7 に統合)の設計をそのまま使う。`role_checks` は `category_checks` と同じ形(チェックの集合＋空送信用の hidden)だが、選択肢は `review.known_roles`(新しいメソッド。`Array(curriculum['courses']).flat_map { |c| c['roles'] }.uniq.sort` に `review.role_names` を添えたラベル)から作る。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '経路をチェックの入力から直す(JSONを使わない)' do
  result = edit(rules: { '0' => { id: 'english_required',
                                  paths: { '0' => { roles: %w[university_english] },
                                          '1' => { roles: %w[english_reading_intermediate] } } } })

  assert result.ok?
  rule = document_after['rules'].find { |r| r['id'] == 'english_required' }
  assert_equal [['university_english'], ['english_reading_intermediate']], rule['paths']
end

test 'any_ofの選択肢をJSONを使わず直す' do
  result = edit(rules: { '0' => { id: 'some_any_of',
                                  options: { '0' => { type: 'credit_sum', categories: %w[a], required_credits: '4' },
                                            '1' => { type: 'grouped_max', category: 'b', group_by: 'number_prefix',
                                                     required_credits: '4' } } } })

  rule = document_after['rules'].find { |r| r['id'] == 'some_any_of' }
  assert_equal [{ 'type' => 'credit_sum', 'categories' => %w[a], 'required_credits' => 4 },
                { 'type' => 'grouped_max', 'category' => 'b', 'group_by' => 'number_prefix', 'required_credits' => 4 }],
               rule['options']
end

test 'all_ofの中にall_ofは置けない(その条件は捨てて指摘する)' do
  result = edit(rules: { '0' => { id: 'some_any_of',
                                  options: { '0' => { type: 'all_of', conditions: { '0' => { type: 'all_of' } } } } } })

  assert_not result.ok?
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_import/requirements_edit/rule_editing_test.rb`
Expected: FAIL

- [ ] **Step 3: 作る**

上の Interfaces のとおりに実装する。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: 実際に画面で通す**

Run: 開発環境で下書きの要件表を開き、one_of_pathsの規則(例: english_required)の経路を1つ足して保存し、再読込しても残ることを確かめる。JSON欄が無いことも確かめる。
Expected: 上のとおりに動く。

- [ ] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: one_of_paths・any_of・all_ofの経路・条件を入れ子のボックスでJSONなしに編集できるようにする"
```

---

### Task 8: 新しい章・行・規則の追加をツリーのUIに統合し、JSON欄を廃止する

**Files:**
- Modify: `app/views/curricula/_requirements_additions.html.erb`（「章を足す」「行を足す」を、ツリーの最後に出す「＋ ルート区分を追加」「＋ 子区分」ボタン相当の、常時見える1行の追加フォームにする。中身(欄)は変えない）、`app/services/curriculum_import/requirements_edit/rule_editing.rb`（`add_new_rule`・`new_rule_problem` を書き直す）、`app/views/curricula/_requirements_rules.html.erb`（「規則を足す(AIが読み落とした要件)」をJSON欄から型選択＋欄のフォームにする。Task 6 でツリーに統合された行の下にはもう出ない規則の一覧はここに残す(入れ子に属さない独立した規則を足す場所として)）
- Test: `test/services/curriculum_import/requirements_edit/rule_editing_test.rb`

**Interfaces:**
- Consumes: Task 5 の `repeater`、Task 7 の `:paths`/`:conditions` coercion、既存の `RequirementsEdit.rule_fields`
- Produces: `@params[:new_rule]`(Hash。`new_rule_json` 文字列は廃止)。`add_new_rule` は `new_rule[:type]` で型を決め、その型の `rule_fields` と同じ欄(`id`・`label`・型ごとの欄。`paths`/`options`/`conditions` を含む)を `assign` と同じ `coerce` を通して組む。

**画面:** 「規則を足す」の中身を、`new_rule[type]` の `<select>`(選択肢は `CurriculumImport::Annotations::RULE_TYPES`)と、`id`・`label`、型ごとの欄(Task 7 で作った `_requirements_rule_paths`/`_requirements_rule_condition` も含めて、既存の規則の編集と同じ部品を再利用する)に変える。JSON欄とサンプルの `<pre>` は消す。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '新しい規則をJSONを使わず型と欄から足す' do
  result = edit(new_rule: { type: 'credit_sum', id: 'added_one', label: '追加分',
                            categories: %w[health], required_credits: '2' })

  assert result.ok?
  rule = document_after['rules'].find { |r| r['id'] == 'added_one' }
  assert_equal 'credit_sum', rule['type']
  assert_equal %w[health], rule['categories']
  assert_equal 2, rule['required_credits']
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_import/requirements_edit/rule_editing_test.rb`
Expected: FAIL

- [ ] **Step 3: 作る**

上の Interfaces のとおりに実装する。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: 実際に画面で通す**

Run: 開発環境で下書きの要件表を開き、「規則を足す」から `credit_sum` を1つ足して保存できることを確かめる。JSON欄・サンプルの `<pre>` が無いことも確かめる。
Expected: 上のとおりに動く。

- [ ] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: 新しい規則の追加をJSON欄から型選択と欄のフォームにし、ツリーのUIに統合する"
```
