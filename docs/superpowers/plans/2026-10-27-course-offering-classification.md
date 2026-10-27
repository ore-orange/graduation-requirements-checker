# 講義の年度・学部・学科での分類と絞り込み 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 保存済みの講義に開講年度と開講学科を持たせ、講義登録の一覧を 年度 / 開講学部 / 開講学科 / 科目番号 / 講義コード / 科目名 で絞り込めるようにする。

**Architecture:** `course_offerings` に `year`（年度）と `department_id`（開講学科への参照）を null 許容で足す。学部は `departments.faculty_id` からたどるので列は持たない。学部・学科は `db/seeds.rb` が作るマスタで、自由入力にしない。取り込みのモーダルで年度・学部・学科を必須で選び、`TimetableUpload` → `TimetableImport::Importer` へ取り込み単位の値として渡す。あわせて `lecture_code` を必須にし、`Importer` の「講義コードが無い行」の引き当て分岐をなくす。一覧の絞り込みは `CourseOfferingSearch` に閉じ込め、条件をページ送りのリンクに引き継ぐ。

**Tech Stack:** Ruby on Rails 8.1 / PostgreSQL / Minitest / Tailwind CSS / Stimulus（Importmap）

**Spec:** [docs/superpowers/specs/2026-10-23-course-offering-classification-design.md](../specs/2026-10-23-course-offering-classification-design.md)

## Global Constraints

- 画面は `LocalAccessOnly` のまま。開発・テスト環境のローカルアクセス以外は 404
- `year` は暦の年ではなく**年度**。2026年度の後期は `year = 2026`
- `course_offerings.year` と `course_offerings.department_id` は **null 許容**。`timetable_uploads` 側の同じ2列は `null: false`
- `course_offerings.lecture_code` は **`null: false`**
- `year` の check 制約は `students.admission_year` と同じ `1..9999`
- 学期は絞り込みの軸にしない。表の列としてだけ出す
- 絞り込みのテキストは部分一致。科目番号・講義コードは大文字小文字を区別しない
- gem を増やさない。ページ送りは既存の `Paginator`（30件ずつ）
- 画面の文言・コメントは日本語。`bin/ci`（RuboCop・Brakeman・テスト）が通ること

## Review Focus

1. **絞り込みのテキストに `%` や `_` を入れたとき** — LIKE のメタ文字として解釈されて関係ない講義に当たってはいけない。文字そのものとして探す（Task 5）
2. **URLで学部と学科が矛盾する組み合わせを渡されたとき**（`faculty_id=工学部` と `department_id=理学部の学科`）— 0件になり、学部の指定が黙って無視されてはいけない（Task 5）
3. **取り込みに、存在しない `department_id` や数字でない `year` を送られたとき** — 500 にせず、理由を出して取り込みを始めない（Task 4）
4. **絞り込んだあとページを送ったとき** — 条件が消えて全件に戻ってはいけない（Task 5）
5. **同じ講義コードを、年度だけ変えて取り込んだとき** — 既存の行を上書きせず、別の行として増える（Task 3）

---

## File Structure

| ファイル | 役割 |
|---|---|
| `db/migrate/20261027100000_add_classification_to_course_offerings.rb` | 列の追加、`lecture_code` 必須化、ユニークインデックスの差し替え、既存データの削除 |
| `db/seeds/academic_organizations.rb`（新規） | 学部・学科のマスタ。表を直すときはこのファイルだけ見ればよいように、データとして分ける |
| `db/seeds.rb` | 上記を環境を問わず読む（デモデータの条件の外） |
| `app/models/faculty.rb` / `department.rb` | 名前の一意性の検証 |
| `app/models/course_offering.rb` | `department` の関連、`lecture_code` の必須と一意性のスコープ |
| `app/models/timetable_upload.rb` | `department` の関連、`build_from_pdf` が年度・学科を受ける、`commit!`/`preview` が `Importer` に渡す |
| `app/models/timetable_upload_row.rb` | `problems` に講義コードの検証を通す |
| `lib/timetable_import/importer.rb` | 取り込み単位の年度・学科、引き当てキーの一本化、講義コードの必須検証 |
| `app/services/course_offering_search.rb`（新規） | 一覧の絞り込みの条件と並び順 |
| `app/controllers/course_registrations_controller.rb` | 絞り込みとページ送り |
| `app/controllers/timetable_uploads_controller.rb` | 年度・学部・学科の受け取りと検証 |
| `app/views/course_registrations/index.html.erb` | 検索バーと1つの表、モーダルの追加項目 |
| `app/views/course_registrations/_search_form.html.erb`（新規） | 検索バー |
| `app/javascript/controllers/dependent_select_controller.js`（新規） | 学部を選ぶと学科の選択肢を絞る |
| `docs/database-design.md` / `README.md` | ER図・表・開発の流れ |

---

## Task 1: 学部・学科のマスタ

**Files:**
- Create: `db/seeds/academic_organizations.rb`
- Create: `db/migrate/20261027000000_add_unique_names_to_academic_organizations.rb`
- Modify: `db/seeds.rb`
- Modify: `app/models/faculty.rb`, `app/models/department.rb`
- Test: `test/models/academic_organization_test.rb`（新規）

**Interfaces:**
- Produces: `AcademicOrganizations.load!` — 学部・学科を `find_or_create_by!` で作る。何度呼んでも増えない。戻り値は使わない

- [ ] **Step 1: 失敗するテストを書く**

`test/models/academic_organization_test.rb`:

```ruby
test '同じ名前の学部は作れない' do
  Faculty.create!(name: '工学部')
  assert_raises(ActiveRecord::RecordInvalid) { Faculty.create!(name: '工学部') }
end

test '同じ学部に同じ名前の学科は作れないが、別の学部なら作れる' do
  kogaku = Faculty.create!(name: '工学部')
  rigaku = Faculty.create!(name: '理学部')
  kogaku.departments.create!(name: '工学科')
  assert_raises(ActiveRecord::RecordInvalid) { kogaku.departments.create!(name: '工学科') }
  assert rigaku.departments.create!(name: '工学科').persisted?
end

test 'マスタは2回流しても増えない' do
  AcademicOrganizations.load!
  faculties = Faculty.count
  departments = Department.count
  AcademicOrganizations.load!
  assert_equal faculties, Faculty.count
  assert_equal departments, Department.count
end

test 'マスタに工学部 工学科がある' do
  AcademicOrganizations.load!
  assert Department.joins(:faculty).exists?(name: '工学科', faculty: { name: '工学部' })
end
```

- [ ] **Step 2: テストが落ちることを確認**

Run: `bin/rails test test/models/academic_organization_test.rb`
Expected: FAIL（`AcademicOrganizations` が未定義、一意性の検証が無い）

- [ ] **Step 3: マイグレーションでユニークインデックスを張る**

`db/migrate/20261027000000_add_unique_names_to_academic_organizations.rb` に、`faculties` の `name` と `departments` の `%i[faculty_id name]` のユニークインデックスを足す。重複があると張れないので、重複があれば `ActiveRecord::IrreversibleMigration` に理由を入れて中止する（`20261016300000_change_courses_credits_to_integer.rb` と同じ書き方）。

Run: `bin/rails db:migrate`

- [ ] **Step 4: モデルに検証を足す**

`Faculty`: `validates :name, presence: true, uniqueness: true`
`Department`: `validates :name, presence: true, uniqueness: { scope: :faculty_id }`

- [ ] **Step 5: マスタのデータを書く**

`db/seeds/academic_organizations.rb` に `AcademicOrganizations.load!` を定義する。中身は設計書「1. 学部・学科のマスタ」の表をそのまま、学部名をキーに学科名の配列を並べた定数にし、`Faculty.find_or_create_by!(name:)` → `faculty.departments.find_or_create_by!(name:)` で作る。

> この表の内容は公式サイト以外の情報源から書いたもの。直すときはこのファイルの定数だけを変える。

| 学部 | 学科 |
|---|---|
| 人文社会学部 | 国際法政学科 / 人間社会学科 / 琉球アジア文化学科 |
| 国際地域創造学部 | 国際地域創造学科 |
| 教育学部 | 学校教育教員養成課程 |
| 理学部 | 数理科学科 / 物質地球科学科 / 海洋自然科学科 |
| 医学部 | 医学科 / 保健学科 |
| 工学部 | 工学科 |
| 農学部 | 亜熱帯地域農学科 / 亜熱帯農林環境科学科 / 地域農業工学科 / 亜熱帯生物資源科学科 |

- [ ] **Step 6: `db/seeds.rb` から読む**

デモデータの条件の外に置き、環境を問わず流す。

```ruby
require_relative 'seeds/academic_organizations'
AcademicOrganizations.load!
DemoData.load! if DemoAccount.enabled?
```

- [ ] **Step 7: テストが通ることを確認**

Run: `bin/rails test test/models/academic_organization_test.rb`
Expected: PASS

- [ ] **Step 8: コミット**

```bash
git add db/migrate db/seeds.rb db/seeds db/schema.rb app/models/faculty.rb app/models/department.rb test/models/academic_organization_test.rb
git commit -m "feat: 学部・学科のマスタをseedで持つ"
```

---

## Task 2: DBの列とモデルの検証

**Files:**
- Create: `db/migrate/20261027100000_add_classification_to_course_offerings.rb`
- Modify: `app/models/course_offering.rb`, `app/models/timetable_upload.rb`, `app/models/department.rb`
- Modify: `test/test_helper.rb`
- Test: `test/models/course_offering_test.rb`（新規）

**Interfaces:**
- Consumes: Task 1 の `AcademicOrganizations.load!`
- Produces:
  - `course_offerings.year`（integer, null 許容）/ `course_offerings.department_id`（bigint, null 許容, FK）
  - `course_offerings.lecture_code`（null: false）、ユニークインデックス `%i[year semester lecture_code]`
  - `timetable_uploads.year`（integer, null: false）/ `timetable_uploads.department_id`（bigint, null: false, FK）
  - `CourseOffering#department` / `TimetableUpload#department`
  - `ActiveSupport::TestCase#test_department` — テスト用の学科を1つ作って返す（同じテスト内では同じものを返す）

- [ ] **Step 1: 失敗するテストを書く**

`test/models/course_offering_test.rb`:

```ruby
test '講義コードは必須' do
  offering = build_offering(lecture_code: nil)
  assert_not offering.valid?
end

test '同じ年度・学期で講義コードは重複できない' do
  build_offering(lecture_code: 'k001').save!
  assert_not build_offering(lecture_code: 'k001').valid?
end

test '年度が違えば同じ講義コードを登録できる' do
  build_offering(year: 2026, lecture_code: 'k001').save!
  assert build_offering(year: 2027, lecture_code: 'k001').valid?
end

test '年度・学科は空でもよい' do
  assert build_offering(year: nil, department: nil).valid?
end
```

`build_offering` はこのテストファイル内の private メソッドで、`Course.create!` した科目と `test_department`、`semester: '前期'`、`year: 2026` を既定にして `CourseOffering.new` を返す。`test_department` は Step 5 で足すので、Step 2 の時点では未定義で落ちる。

- [ ] **Step 2: テストが落ちることを確認**

Run: `bin/rails test test/models/course_offering_test.rb`
Expected: FAIL（`year` / `department` の列が無い）

- [ ] **Step 3: マイグレーションを書く**

`db/migrate/20261027100000_add_classification_to_course_offerings.rb`。`up` / `down` で書く（データを消すので `change` にしない）。

`up` の順序:

1. 既存データを消す（設計で消してよいと決めた）。`TimetableUpload` の行 → `course_offerings` の行 → 取り込みが作った `courses`。`courses` は `curriculum_key IS NULL` かつ `student_courses` / `planned_courses` から参照されていない行だけを消す。消せずに残った件数は `say` でログに出す
2. `course_offerings` に `t.integer :year` と `t.references :department, foreign_key: true`（どちらも null 許容）を足す
3. `course_offerings.lecture_code` を `null: false` にする
4. 古いインデックス `%i[semester lecture_code]` を落とし、`%i[year semester lecture_code]` のユニークインデックスを張る（`where` 条件なし）
5. `course_offerings` に `year` の check 制約（`year IS NULL OR (year >= 1 AND year <= 9999)`、名前 `course_offerings_year_range`）
6. `timetable_uploads` に `t.integer :year, null: false` と `t.references :department, null: false, foreign_key: true` を足す。既存行は 1 で消してあるので既定値は要らない
7. `timetable_uploads` に `year` の check 制約（`year >= 1 AND year <= 9999`、名前 `timetable_uploads_year_range`）

`down` は 2〜7 を逆に戻す（消したデータは戻さない）。

Run: `bin/rails db:migrate`
Expected: `db/schema.rb` が更新される

- [ ] **Step 4: モデルを直す**

`CourseOffering`:
- `belongs_to :department, optional: true`
- `validates :lecture_code, presence: true`
- `validates :lecture_code, uniqueness: { scope: %i[year semester] }`（`allow_nil` は外す）
- `validates :year, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 9999 }, allow_nil: true`

`TimetableUpload`: `belongs_to :department`
`Department`: `has_many :course_offerings, dependent: :restrict_with_error`

- [ ] **Step 5: テスト用のヘルパーを足す**

`test/test_helper.rb` の `ActiveSupport::TestCase` に:

```ruby
# 分類に使う学科。テストごとに1つだけ作って使い回す。
def test_department
  @test_department ||= Faculty.create!(name: 'テスト学部').departments.create!(name: 'テスト学科')
end
```

- [ ] **Step 6: テストが通ることを確認**

Run: `bin/rails test test/models/course_offering_test.rb`
Expected: PASS

- [ ] **Step 7: コミット**

```bash
git add db/migrate db/schema.rb app/models test/test_helper.rb test/models/course_offering_test.rb
git commit -m "feat: 講義に開講年度と開講学科を持たせ、講義コードを必須にする"
```

---

## Task 3: 取り込み処理（Importer）

**Files:**
- Modify: `lib/timetable_import/importer.rb`
- Modify: `app/models/timetable_upload.rb`, `app/models/timetable_upload_row.rb`
- Test: `test/lib/timetable_import/importer_test.rb`

**Interfaces:**
- Consumes: Task 2 の列と `test_department`
- Produces:
  - `TimetableImport::Importer.new(rows, year:, department_id:)` — 年度・学科は取り込み全体で1つ。行のハッシュには入れない
  - `TimetableUpload#preview` / `#commit!` は自分の `year` / `department_id` を渡す

- [ ] **Step 1: 失敗するテストを書く**

`test/lib/timetable_import/importer_test.rb` に足す／置き換える。

```ruby
test '年度と学科が開講情報に入る' do
  result = import([row(lecture_code: 'k001')], year: 2026)
  assert result.applied
  offering = CourseOffering.sole
  assert_equal 2026, offering.year
  assert_equal test_department.id, offering.department_id
end

test '同じ年度・学期・講義コードの取り込みは更新になる' do
  import([row(lecture_code: 'k001', weekday: '月')], year: 2026)
  result = import([row(lecture_code: 'k001', weekday: '火')], year: 2026)
  assert_equal 1, CourseOffering.count
  assert_equal 1, result.updated_offerings
  assert_equal '火', CourseOffering.sole.weekday
end

test '年度が違えば別の行として増える' do
  import([row(lecture_code: 'k001')], year: 2026)
  result = import([row(lecture_code: 'k001')], year: 2027)
  assert_equal 2, CourseOffering.count
  assert_equal 1, result.created_offerings
  assert_equal [2026, 2027], CourseOffering.order(:year).pluck(:year)
end

test '講義コードが空の行はエラーになり、何も保存しない' do
  result = import([row(lecture_code: '')], year: 2026)
  assert_not result.applied
  assert_includes result.errors.join, '講義コード'
  assert_equal 0, CourseOffering.count
end
```

`import(rows, year:)` はこのテストファイル内の private メソッドで、`TimetableImport::Importer.new(rows, year: year, department_id: test_department.id).call(apply: true)` を返す。既にある「講義コードが無い行を科目・曜日・時限で引き当てる」テストは**消す**（その分岐をなくすため）。残りのテストには `lecture_code` を足す。

- [ ] **Step 2: テストが落ちることを確認**

Run: `bin/rails test test/lib/timetable_import/importer_test.rb`
Expected: FAIL（`Importer.new` が引数を受けない）

- [ ] **Step 3: `Importer` を直す**

- `initialize(rows, year:, department_id:)` にし、`@year` / `@department_id` を持つ
- `RowAttributes#validate` に「講義コードが空です。」の検証を足す（`lecture_code` が nil のとき）
- `RowAttributes#offering_attributes` から学期以外は変えない。年度・学科は `save_offering` が `attrs.offering_attributes.merge(course: course, year: @year, department_id: @department_id)` で足す
- `find_offering` を1本にする: `CourseOffering.find_or_initialize_by(year: @year, semester: attrs.semester, lecture_code: attrs.lecture_code)`。`course` + 曜日・時限で引き当てる分岐は消す
- 講義コードの重複エラーのメッセージは今のまま

- [ ] **Step 4: 呼び出し側を直す**

`TimetableUpload#preview` と `#commit!` が `TimetableImport::Importer.new(rows.map(&:importer_row), year: year, department_id: department_id)` を呼ぶようにする。

`TimetableUploadRow#problems` は `RowAttributes.new(importer_values)` を通しているので、講義コードの検証は自動で効く。確認画面で講義コードが空の行が確認済みにできないことを `test/models/timetable_upload_test.rb` にテストで足す。

```ruby
test '講義コードが空の行は確認済みにできない' do
  upload = create_upload
  row = upload.rows.create!(position: 1, name: '情報処理概論', credits: '2', lecture_code: '')
  result = upload.apply_edits({ row.id.to_s => {} }, [row.id.to_s])
  assert_includes result.failures[row.id.to_s].join, '講義コード'
  assert_not row.reload.confirmed
end
```

あわせて `test/models/timetable_upload_test.rb` の中で `TimetableUpload.create!` している箇所すべてに `year: 2026, department: test_department` を足す（Task 2 で `null: false` にしたため）。この置き換えを private メソッド `create_upload` にまとめる。

- [ ] **Step 5: テストが通ることを確認**

Run: `bin/rails test test/lib/timetable_import/importer_test.rb test/models/timetable_upload_test.rb`
Expected: PASS

- [ ] **Step 6: コミット**

```bash
git add lib/timetable_import/importer.rb app/models test/lib test/models
git commit -m "feat: 取り込みで年度・学科を保存し、講義コードを必須にする"
```

---

## Task 4: 取り込みのときに年度・学部・学科を選ぶ

**Files:**
- Modify: `app/controllers/timetable_uploads_controller.rb`
- Modify: `app/models/timetable_upload.rb`
- Modify: `app/views/course_registrations/index.html.erb`（モーダル）
- Modify: `app/views/timetable_uploads/show.html.erb`（見出し）
- Create: `app/javascript/controllers/dependent_select_controller.js`
- Test: `test/controllers/course_registrations_test.rb`

**Interfaces:**
- Consumes: Task 3 の `Importer` の引数、Task 1 のマスタ
- Produces: `TimetableUpload.build_from_pdf(pdf_path, semester:, year:, department_id:, filename:)`

- [ ] **Step 1: 失敗するテストを書く**

`test/controllers/course_registrations_test.rb` に足す。既存の `TimetableUpload.create!(semester: …)` を使っている箇所には `year:` と `department:` を足す。

```ruby
test '年度・学部・学科を選んで取り込むと、取り込みに残る' do
  post timetable_uploads_path, params: upload_params(year: 2026, department_id: test_department.id)
  assert_equal 2026, TimetableUpload.sole.year
  assert_equal test_department.id, TimetableUpload.sole.department_id
end

test '年度が数字でないときは取り込まない' do
  post timetable_uploads_path, params: upload_params(year: 'あ')
  assert_redirected_to course_registrations_path
  assert_equal 0, TimetableUpload.count
  assert_match '年度', flash[:alert]
end

test '学科が選ばれていないときは取り込まない' do
  post timetable_uploads_path, params: upload_params(department_id: '')
  assert_equal 0, TimetableUpload.count
  assert_match '学科', flash[:alert]
end

test '存在しない学科IDでは取り込まない' do
  post timetable_uploads_path, params: upload_params(department_id: '999999')
  assert_equal 0, TimetableUpload.count
  assert_match '学科', flash[:alert]
end
```

`upload_params` はこのテストファイル内の private メソッドで、既にあるPDFのフィクスチャ（`test/fixtures/files`）を使って `{ semester: '前期', year: 2026, department_id: test_department.id, pdf: fixture_file_upload(...) }` を作り、引数で上書きする。

- [ ] **Step 2: テストが落ちることを確認**

Run: `bin/rails test test/controllers/course_registrations_test.rb`
Expected: FAIL

- [ ] **Step 3: コントローラの検証を足す**

`TimetableUploadsController#upload_error` に、学期の次の順で検証を足す。

- 年度: `Integer(params[:year].to_s, 10, exception: false)` が 1..9999 でなければ `'年度を選んでください。'`
- 学科: `Department.exists?(id: params[:department_id])` でなければ `'開講学部と開講学科を選んでください。'`

`#create` が `year:` と `department_id:` を `build_from_pdf` に渡す。`TimetableUpload.build_from_pdf` は受け取った値を `create!` に渡す。

- [ ] **Step 4: モーダルに項目を足す**

`app/views/course_registrations/index.html.erb` の `dialog` 内、学期のラジオボタンの前に3つ。

- 年度: `form.select :year`。選択肢は `@year_options`（コントローラが作る。今年度を中心に前後2年）。既定は今年度
- 開講学部: `form.select :faculty_id`。選択肢は `@faculties`。先頭は「選んでください」
- 開講学科: `form.select :department_id`。選択肢は**全学科**を `optgroup` で学部ごとに出し、`dependent_select` コントローラが選ばれた学部のものだけ残す

`CourseRegistrationsController#index` に `@faculties = Faculty.includes(:departments).order(:id)` と `@year_options` を足す。

- [ ] **Step 5: Stimulus コントローラを書く**

`app/javascript/controllers/dependent_select_controller.js`。targets は `parent`（学部の select）と `child`（学科の select）。`parent` の `change` で、`child` の `optgroup` のうち選ばれた学部のものだけを表示し、他は隠して選択を外す。学部が未選択なら学科も未選択にして無効にする。既存の `modal` / `dropzone` コントローラと同じ書き方にそろえる。

- [ ] **Step 6: 確認画面の見出しに分類を出す**

`app/views/timetable_uploads/show.html.erb` の見出しに「2026年度 工学部 工学科 前期」を出す。学部名は `@upload.department.faculty.name`。

- [ ] **Step 7: テストが通ることを確認**

Run: `bin/rails test test/controllers/course_registrations_test.rb`
Expected: PASS

- [ ] **Step 8: コミット**

```bash
git add app/controllers app/models app/views app/javascript test/controllers
git commit -m "feat: 取り込みのときに年度・開講学部・開講学科を選ぶ"
```

---

## Task 5: 一覧の検索バーと表

**Files:**
- Create: `app/services/course_offering_search.rb`
- Create: `app/views/course_registrations/_search_form.html.erb`
- Modify: `app/controllers/course_registrations_controller.rb`
- Modify: `app/views/course_registrations/index.html.erb`
- Test: `test/services/course_offering_search_test.rb`（新規）, `test/controllers/course_registrations_test.rb`

**Interfaces:**
- Consumes: Task 2 の列
- Produces:
  - `CourseOfferingSearch.new(params)` with:
    - `#relation` → `ActiveRecord::Relation`（絞り込み済み・並び順つき・`includes(:course, department: :faculty)`）
    - `#conditions` → `Hash`（指定のあった条件だけ。ページ送りのリンクとフォームの再表示に使う）
    - `#filtered?` → `Boolean`
  - 受け取るキー: `:year`, `:faculty_id`, `:department_id`, `:course_number`, `:lecture_code`, `:name`

- [ ] **Step 1: 失敗するテストを書く**

`test/services/course_offering_search_test.rb`:

```ruby
test '条件が無ければ全件を年度の新しい順で返す' do
  older = create_offering(year: 2025, lecture_code: 'k001')
  newer = create_offering(year: 2026, lecture_code: 'k002')
  assert_equal [newer, older], CourseOfferingSearch.new({}).relation.to_a
end

test '年度で絞り込む' do
  create_offering(year: 2025, lecture_code: 'k001')
  hit = create_offering(year: 2026, lecture_code: 'k002')
  assert_equal [hit], CourseOfferingSearch.new(year: '2026').relation.to_a
end

test '学部で絞り込むと、その学部の全学科が当たる' do
  hit = create_offering(lecture_code: 'k001', department: test_department)
  other = Faculty.create!(name: '別学部').departments.create!(name: '別学科')
  create_offering(lecture_code: 'k002', department: other)
  assert_equal [hit], CourseOfferingSearch.new(faculty_id: test_department.faculty_id.to_s).relation.to_a
end

test '学部と学科が矛盾するときは0件になる' do
  create_offering(lecture_code: 'k001', department: test_department)
  other = Faculty.create!(name: '別学部').departments.create!(name: '別学科')
  search = CourseOfferingSearch.new(faculty_id: other.faculty_id.to_s, department_id: test_department.id.to_s)
  assert_empty search.relation
end

test '科目名は部分一致で当たる' do
  hit = create_offering(lecture_code: 'k001', course_name: '情報処理概論')
  create_offering(lecture_code: 'k002', course_name: '線形代数')
  assert_equal [hit], CourseOfferingSearch.new(name: '情報').relation.to_a
end

test '講義コードは大文字小文字を区別しない' do
  hit = create_offering(lecture_code: 'K00123001')
  assert_equal [hit], CourseOfferingSearch.new(lecture_code: 'k00123').relation.to_a
end

test 'LIKEのメタ文字は文字そのものとして扱う' do
  hit = create_offering(lecture_code: 'k001', course_number: 'T_1')
  create_offering(lecture_code: 'k002', course_number: 'TX1')
  assert_equal [hit], CourseOfferingSearch.new(course_number: 'T_1').relation.to_a
end

test '年度・学科が空の講義も、条件が無ければ出る' do
  blank = create_offering(lecture_code: 'k001', year: nil, department: nil)
  assert_includes CourseOfferingSearch.new({}).relation, blank
end

test 'conditions は指定のあった条件だけを返す' do
  search = CourseOfferingSearch.new(year: '2026', name: '', faculty_id: nil)
  assert_equal({ year: '2026' }, search.conditions)
end
```

`create_offering` はこのテストファイル内の private メソッドで、`Course.create!(name:, course_number:)` と `test_department`・`semester: '前期'`・`year: 2026` を既定にして `CourseOffering.create!` を返す。

- [ ] **Step 2: テストが落ちることを確認**

Run: `bin/rails test test/services/course_offering_search_test.rb`
Expected: FAIL（`CourseOfferingSearch` が未定義）

- [ ] **Step 3: `CourseOfferingSearch` を書く**

`app/services/course_offering_search.rb`。

- 部分一致は `ActiveRecord::Base.sanitize_sql_like` でメタ文字を潰してから `ILIKE` に渡す（`course_number` と `lecture_code`）。科目名も同じく `ILIKE`
- 科目名・科目番号は `courses` の列なので `joins(:course)`
- 学部は `joins(department: :faculty)` ではなく `where(department_id: Department.where(faculty_id: ...))` で絞る（学科が空の行を落とさないため、学科の条件が無いときは `left_joins` の挙動に頼らない）
- 並び順は `year: :desc`, `semester`, `weekday`, `periods`, `id`
- `conditions` は受け取ったキーのうち `present?` のものだけを `Symbol => String` で返す

- [ ] **Step 4: テストが通ることを確認**

Run: `bin/rails test test/services/course_offering_search_test.rb`
Expected: PASS

- [ ] **Step 5: コントローラの失敗するテストを書く**

`test/controllers/course_registrations_test.rb`:

```ruby
test '絞り込むと当たった講義だけが出る' do
  create_offering(lecture_code: 'k001', course_name: '情報処理概論')
  create_offering(lecture_code: 'k002', course_name: '線形代数')
  get course_registrations_path(name: '情報')
  assert_response :success
  assert_select 'td', text: '情報処理概論'
  assert_select 'td', text: '線形代数', count: 0
end

test '絞り込みの条件はページ送りのリンクに残る' do
  31.times { |i| create_offering(lecture_code: "k#{i}", course_name: '情報処理概論') }
  get course_registrations_path(name: '情報')
  assert_select 'nav[aria-label=ページ送り] a[href*="name=情報"]'
end

test '条件に当たる講義が無いときは、その旨を出す' do
  create_offering(lecture_code: 'k001', course_name: '線形代数')
  get course_registrations_path(name: '当たらない')
  assert_select 'body', text: /条件に当たる講義がありません/
end

test 'まだ1件も保存されていないときは、別の案内を出す' do
  get course_registrations_path
  assert_select 'body', text: /まだ保存された講義はありません/
end
```

- [ ] **Step 6: テストが落ちることを確認**

Run: `bin/rails test test/controllers/course_registrations_test.rb`
Expected: FAIL

- [ ] **Step 7: コントローラと画面を直す**

`CourseRegistrationsController#index`:

```ruby
@search = CourseOfferingSearch.new(params)
@paginator = Paginator.new(total: @search.relation.count, page: params[:page])
@offerings = @search.relation.offset(@paginator.offset).limit(@paginator.per)
```

`@offerings` を `group_by(&:semester)` するのはやめる（表は1つ）。

`app/views/course_registrations/_search_form.html.erb` に検索バーを書く。`form_with url: course_registrations_path, method: :get` で、年度（「すべて」＋ `CourseOffering.distinct.order(year: :desc).pluck(:year).compact`）、開講学部、開講学科（Task 4 と同じ `optgroup` ＋ `dependent_select`）、科目番号・講義コード・科目名のテキスト、「しぼりこむ」と「条件を消す」（`course_registrations_path` へのリンク）。

`index.html.erb` の「保存済みの講義」を1つの表にする。列は 年度 / 学期 / 学部・学科 / 科目番号 / 講義コード / 科目名 / 単位 / 必修選択 / 年次 / 曜日 / 時限。年度・学科が空のセルは `—` と出す。

空のときの文言を2つに分ける。`@search.filtered?` が真なら「条件に当たる講義がありません。」、偽なら今の「まだ保存された講義はありません。…」。

ページ送りの `path` lambda に条件を混ぜる: `->(page) { course_registrations_path(@search.conditions.merge(page: page)) }`

「確認中のPDF」の各行に、年度・学部・学科を足す。

- [ ] **Step 8: テストが通ることを確認**

Run: `bin/rails test test/controllers/course_registrations_test.rb`
Expected: PASS

- [ ] **Step 9: コミット**

```bash
git add app/services app/controllers app/views test
git commit -m "feat: 保存済みの講義を年度・学部・学科・科目名などで絞り込めるようにする"
```

---

## Task 6: 文書を直す

**Files:**
- Modify: `docs/database-design.md`
- Modify: `README.md`

- [ ] **Step 1: `docs/database-design.md` を直す**

- ER図に `departments ||--o{ course_offerings` を足す
- `course_offerings` の行に、`year`（年度、NULL可）・`department_id`（開講学科、NULL可）・`lecture_code` が必須になったこと・ユニークは `(year, semester, lecture_code)` であることを書く
- `timetable_uploads` の行に、年度・開講学科を取り込みのときに選ぶことを書く
- `faculties` / `departments` の名前が一意になったことを書く

- [ ] **Step 2: `README.md` を直す**

- 講義登録の説明に、取り込みのときに年度・開講学部・開講学科を選ぶこと、講義コードが必須であることを書く
- 開発の流れに、**まっさらなDBでは `bin/rails db:seed` を流さないと学部・学科のプルダウンが空になる**ことを書く

- [ ] **Step 3: `bin/ci` を通す**

Run: `bin/ci`
Expected: RuboCop・YAML・gem監査・Brakeman・テストがすべて PASS

- [ ] **Step 4: コミット**

```bash
git add docs/database-design.md README.md
git commit -m "docs: 年度・学部・学科での分類をDB設計とREADMEに反映する"
```
