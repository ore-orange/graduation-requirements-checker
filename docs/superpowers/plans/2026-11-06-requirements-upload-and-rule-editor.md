# 取り込みフォームの見直しと規則エディタのJSON廃止 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 便覧PDFの取り込みフォームを「対象を選ぶ」カードと同じ見た目のプルダウンにし、学部・学科・コースを既存DB（Faculty/Department/Program）から選ばせる。入学年度の範囲を2016年度〜来年度に揃え、表示を「2024年」のような年だけにする。共通教育は科目番号のパターンで判定できるようにして、取り込みの科目表には載せない。要件表の規則編集は、JSON欄を使わず画面の入力だけで作れるようにする（one_of_paths・any_of・all_of を含む）。

**Architecture:** 学部・学科・コースの選択肢は `Faculty`/`Department`/`Program`（既存のAR）から作る。`Curriculum#department_name` は今までどおり「学科・コース名」を1つの文字列で持つ（スキーマは変えない）。画面には学科とコースを別のプルダウンで出し、コントローラが選ばれた学科名とコース名を1つの文字列に結んでから `department_name` に渡す（人が手で「工学科 知能情報コース」と打っていたのと同じ値になる。コースの無い学科は学科名だけになる、今までと同じ）。共通教育の判定は、`GraduationAssessment::Catalogue` に「科目表に無い科目でも、区分の `number_patterns` に科目番号が一致すれば、その区分として数える」という推定経路を1つ足す（既存の科目表と役割の仕組みには触れない）。規則エディタは、`one_of_paths.paths`・`any_of.options`・`all_of.conditions` を、既存の `rule_fields` と同じ「欄ごとに直せる」考え方の上に、繰り返し行（パス・条件）を増減できるUIで置き換える。繰りり返し行の増減は、新しい汎用の Stimulus コントローラ（配列パラメータの `[]` 記法をそのまま使い、添字の付け替えをしない）で行う。

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

### Task 6: one_of_pathsの経路をJSONなしで編集できるようにする

**Files:**
- Modify: `app/services/curriculum_import/requirements_edit.rb`（`RULE_FIELD_KINDS` に `paths: :paths`・`RULE_EXTRA_FIELDS`は変えない）、`app/services/curriculum_import/requirements_edit/coercion.rb`（`coerce`・`same?`・`baseline` に `:paths` を足す）、`app/helpers/requirements_review_helper.rb`（`rule_field_control`・新しい `role_checks`）、`app/views/curricula/_requirements_rules.html.erb`（`paths` の行を repeater で出す）
- Test: `test/services/curriculum_import/requirements_edit/rule_editing_test.rb`(既存。無い名前のメソッドなら近い既存ファイルに足す)、`test/helpers/requirements_review_helper_test.rb`

**Interfaces:**
- Consumes: Task 5 の `repeater` コントローラ
- Produces: `Coercion#coerce(value, :paths, name)` が `rules[N][paths][]`(各経路が1つの `<select multiple>` またはチェックの集合)を `Array<Array<String>>` にする。画面からの送信形は `rules[N][paths][0][roles][]=a&rules[N][paths][0][roles][]=b&rules[N][paths][1][roles][]=c`(経路ごとに添字、経路内の役割は `[]`)。

**パラメータの形:** `entry[:paths]` は `{ "0" => { "roles" => ["a","b"] }, "1" => { "roles" => ["c"] } }` の形(Railsが `paths[0][roles][]=...` をこう組む)。`coerce` の `:paths` 分岐は、これを `値.values.map { |path| Array(path['roles']).reject(&:blank?) }` にし、空の経路(`roles` が空)は捨てる(Validation::Input の `paths?` が空配列や空の経路を拒むのと揃える。空にした経路は「無かった」ことにする)。全部の経路を消したときは `paths: []` を送る(Bookkeeping の「送らなければ消さない」原則どおり、`paths` キー自体が params に無ければ触らない)。

**画面:** `rule_field_control` が `kind == :paths` のとき、`data-controller="repeater"` の中に、既存の経路ごとに1行(`role_checks("#{name}[#{index}][roles]", path, review)`)を出し、`<template>` にも空の1行を置く(足すボタンを押すと空の経路が増える)。`role_checks` は `category_checks` と同じ形(チェックの集合＋空送信用の hidden)だが、選択肢は `review.known_roles`(新しいメソッド。`Array(curriculum['courses']).flat_map { |c| c['roles'] }.uniq.sort` に `role_names` を添えたラベル)から作る。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# requirements_edit のテスト(既存ファイルに追記)
test '経路をチェックの入力から直す(JSONを使わない)' do
  result = edit(rules: { '0' => { id: 'english_required',
                                  paths: { '0' => { roles: %w[university_english] },
                                          '1' => { roles: %w[english_reading_intermediate] } } } })

  assert result.ok?
  rule = document_after['rules'].find { |r| r['id'] == 'english_required' }
  assert_equal [['university_english'], ['english_reading_intermediate']], rule['paths']
end

test '空の経路は保存しない' do
  result = edit(rules: { '0' => { id: 'english_required',
                                  paths: { '0' => { roles: %w[university_english] }, '1' => { roles: [''] } } } })

  rule = document_after['rules'].find { |r| r['id'] == 'english_required' }
  assert_equal [['university_english']], rule['paths']
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_import/requirements_edit/rule_editing_test.rb`
Expected: FAIL

- [ ] **Step 3: 作る**

上の Interfaces のとおりに実装する。`rule_summary`(`path_lines`)はすでに `paths` を読んで表示しているので変えない。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: 実際に画面で通す**

Run: 開発環境で下書きの要件表を開き、`one_of_paths` の規則(例: `english_required`)の「この規則を直す・消す」を開き、経路を1つ足して保存し、再読込しても残ることを確かめる。JSON欄が無いことも確かめる。
Expected: 上のとおりに動く。

- [ ] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: one_of_pathsの経路をJSONなしで編集できるようにする"
```

---

### Task 7: any_of・all_ofの入れ子条件をJSONなしで編集できるようにする

**Files:**
- Modify: `app/services/curriculum_import/requirements_edit.rb`（`RULE_FIELD_KINDS` に `list: :conditions` を足す。`RULE_FIELD_KINDS` のキーは `Validation::Input::FIELD_KINDS` 側の種類(`:keys`/`:paths`/`:list`/`:number`/`:count`/`:text`)で、`:list` を使う欄は `any_of.options`・`all_of.conditions` の2つだけなので、field名での特別扱いは要らない。ここで足す `:conditions` は `Coercion` 側の新しい種類の名前で、既存の `Coercion#coerce` の `:list`(単純なid配列)とは別物として並べる）、`app/services/curriculum_import/requirements_edit/coercion.rb`（`:conditions` を足す。再帰的に `credit_sum`/`grouped_max`/(any_ofのときのみ)`all_of` を1条件ずつ組む）
- Create: `app/views/curricula/_requirements_rule_condition.html.erb`（1条件分の型選択＋欄。`all_of` を選んだときは自分自身を repeater で再帰的に呼ぶ）
- Modify: `app/views/curricula/_requirements_rules.html.erb`（`options`/`conditions` の行を `_requirements_rule_condition` の repeater で出す）
- Test: `test/services/curriculum_import/requirements_edit/rule_editing_test.rb`、`test/helpers/requirements_review_helper_test.rb`

**Interfaces:**
- Consumes: Task 5 の `repeater`、Task 6 の `:paths` 実装と同じ Coercion の形(`entries.values` パターン)
- Produces: `rules[N][options][M][type]`・`rules[N][options][M][categories][]`・`rules[N][options][M][required_credits]`(credit_sumのとき)、`rules[N][options][M][category]`・`[group_by]`・`[required_credits]`(grouped_maxのとき)、`rules[N][options][M][type]=all_of` を選んだときは `rules[N][options][M][conditions][K][...]`(1階層だけ、`ALL_OF_CONDITIONS`の2つの型のみ)。

**条件オブジェクトの組み方:** `coerce` の `:conditions` 分岐は、送られた `{ "0" => {type: 'credit_sum', categories: [...], required_credits: '10'}, "1" => {...} }` を、`type` ごとに `Validation::Input::FIELD_KINDS.fetch(type)` の欄だけを `number`/`set` と同じ `coerce` ロジックで組み立て直し、`{ 'type' => type, 'categories' => [...], 'required_credits' => 10 }` のような1条件のHashにする(id・labelは持たない。条件は親の規則の一部で、単独では確認済みの印も付かない)。`type` が `all_of`(any_ofの中でだけ許す)なら、`conditions` を同じ要領で再帰的に組む(1階層だけ。`all_of` の中にさらに `all_of`/`any_of` が来たら、その条件ごと捨てて `error` を積む。`ALL_OF_CONDITIONS`/`ANY_OF_OPTIONS` に無い `type` も同様に拒む)。空の `type` の条件行(足すボタンを押しただけで中身を選んでいない)は捨てる。

**画面:** `_requirements_rule_condition` は、`<select>` で型を選ぶ欄(`options_for_select` の選択肢は、呼ばれた文脈が `any_of` なら `ANY_OF_OPTIONS`、`all_of` なら `ALL_OF_CONDITIONS`。local変数で渡す)と、選んだ型に応じて `rule_field_input` を型ごとの欄数だけ出す(JSで動的に出し分けず、`credit_sum`なら`categories`・`required_credits`、`grouped_max`なら`category`・`group_by`・`required_credits`の欄を**両方とも常に表示**し、使わない欄は空のまま送ってもらう形にする。`type` に応じて実際に使う欄だけを `coerce` 側が読むので、余分な欄があっても害は無い。画面を単純にするための割り切りで、JSで出し分ける案は取らない)。`all_of` を選んだときだけ、その中に `conditions` の repeater をもう1段ネストする(`_requirements_rule_condition` 自身を `local: { allowed: GraduationAssessment::Rules::ALL_OF_CONDITIONS }` で呼び直す。再帰は1回だけなので、パーシャルの再帰呼び出しで十分)。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
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

Run: 開発環境で `any_of`/`all_of` を含む規則(2024年度のデータに実例が無ければ、テスト用の下書きを1つ作って確認する)を開き、JSON欄を使わずに条件を1つ足して保存できることを確かめる。
Expected: 上のとおりに動く。

- [ ] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: any_of・all_ofの入れ子条件をJSONなしで編集できるようにする"
```

---

### Task 8: 新規規則の追加をJSON欄から型選択＋欄のフォームにする

**Files:**
- Modify: `app/services/curriculum_import/requirements_edit/rule_editing.rb`（`add_new_rule`・`new_rule_problem` を書き直す）、`app/views/curricula/_requirements_rules.html.erb`（「規則を足す」の中身を差し替える）
- Test: `test/services/curriculum_import/requirements_edit/rule_editing_test.rb`

**Interfaces:**
- Consumes: Task 6・8 の `:paths`/`:conditions` coercion、既存の `RequirementsEdit.rule_fields`
- Produces: `@params[:new_rule]`(Hash。`new_rule_json` 文字列は廃止)。`add_new_rule` は `new_rule[:type]` で型を決め、その型の `rule_fields` と同じ欄(`id`・`label`・型ごとの欄)を `assign` と同じ `coerce` を通して組む。

**画面:** 「規則を足す」の中身を、`new_rule[type]` の `<select>`(選択肢は `CurriculumImport::Annotations::RULE_TYPES`)と、`id`・`label`、型ごとの欄(Task 6・8 で作った `paths`/`options`/`conditions` のUIも含めて、既存の規則の編集と同じ部品を再利用する。`rule_fields` がダミーの `{'id' => rule_id, 'type' => type}` から欄の種類を返すので、既存の規則を直す行と同じ `each` ループで欄を出せる)に変える。JSON欄とサンプルの `<pre>` は消す。

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
git commit -m "feat: 新しい規則の追加をJSON欄から型選択と欄のフォームにする"
```
