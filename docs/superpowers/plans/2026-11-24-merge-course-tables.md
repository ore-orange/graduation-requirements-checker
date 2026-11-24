# courses と course_offerings の統合 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `course_offerings` を廃止して `courses` に統合し、授業時間配当表の1行をDBの1行として保存できるようにする。

**Architecture:** `courses` に開講の列（年度・学期・講義コード・必修選択・受講年次・曜日・時限・開講区分・開講学科）を移し、講義の同一性を `(year, semester, lecture_code)` の部分unique indexだけで決める。便覧（カリキュラムJSON）由来の科目は、それらの列が空の行として同じテーブルに同居する。その結果、取り込みから「既存の科目に紐づけるか新規登録か」を人に選ばせる仕組みを丸ごと削除できる。

**Tech Stack:** Ruby 3.4.13 / Rails 8.1 / Active Record / PostgreSQL 17 / Minitest / RuboCop

**Spec:** [docs/superpowers/specs/2026-11-24-merge-course-tables-design.md](../specs/2026-11-24-merge-course-tables-design.md)

## Global Constraints

- 統合後のテーブル名は `courses`。`course_offerings` はテーブルもモデルも廃止する。
- unique index：`(year, semester, lecture_code) WHERE lecture_code IS NOT NULL`、名前は `index_courses_on_year_and_semester_and_lecture_code`。
- `curriculum_key` の部分unique index（`WHERE curriculum_key IS NOT NULL`）はそのまま残す。
- check制約の名前：`courses_offering_pair` / `courses_semester` / `courses_requirement_type` / `courses_year_range`。既存の `courses_nonnegative_credits` はそのまま。
- `courses_offering_pair` の条件：`(lecture_code IS NULL AND semester IS NULL) OR (lecture_code IS NOT NULL AND semester IS NOT NULL)`
- `grade_years` / `periods` は `integer[]`、`null: false`、既定 `[]`。
- `year` / `department_id` / `semester` / `lecture_code` はNULL可（便覧由来の行のため）。
- 移行で `curriculum_key` を他の行にコピーしてはいけない。
- コメントは日本語。既存コードにそろえ、「何をしているか」ではなく「なぜそうなっているか」を書く。
- 各タスクの最後に `bundle exec rubocop` が通ること。
- コミットメッセージは日本語の Conventional Commits（`feat:` / `refactor:` / `docs:` / `test:`）。末尾に `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` を付ける。
- DBは `docker compose` の PostgreSQL。`bin/rails db:migrate` / `bin/rails test` で動かす。

## Review Focus

仕様が前提にしているが、素直に書くとテストが当たらない入力。それぞれ担当タスクにテストを足す。

1. 移行時、`curriculum_key` を持つ科目行に開講行が紐づいていた場合 → キーをコピーすると `index_courses_on_curriculum_key` に当たって移行が途中で死ぬ。キーは移さず別行にする（Task 1）。
2. 移行時、1つの科目に2件以上の開講がある場合 → 1件目は科目行をその場で更新して `id` を保ち、2件目以降を新しい行にする。`student_courses` / `planned_courses` の `course_id` が切れてはいけない（Task 1）。
3. 列を落とす前に始めた確認中の取り込み → migration後も確認画面が開けて保存できること。行を消さないのが設計の意図（Task 2）。
4. 同じ科目番号・科目名の講義が既に登録済みの行 → もうエラーにせず、別の行として保存すること（引き当て判断を消した結果の中心的な振る舞い）（Task 2）。
5. 便覧の科目だけがDBにある状態の講義登録画面 → 「まだ保存された講義はありません」の案内が出て、年度も講義コードも空の行だけの表にならないこと（Task 3）。

---

## File Structure

| ファイル | 役割 |
| --- | --- |
| `db/migrate/20261124000000_merge_course_offerings_into_courses.rb`（新規） | 列追加・データ移行・`timetable_upload_rows` の選択列削除・制約追加・`course_offerings` 削除 |
| `app/models/course.rb`（修正） | 統合テーブルのモデル。`CourseOffering` の定数と検証を引き取る |
| `app/models/course_offering.rb`（削除） | — |
| `app/models/department.rb`（修正） | `has_many :course_offerings` → `has_many :courses` |
| `app/models/timetable_upload_row.rb`（修正） | 科目引き当て関連のメソッドを削除 |
| `app/models/timetable_upload.rb`（修正） | `assign_default_course_choice` の呼び出しを削除 |
| `lib/timetable_import/importer.rb`（修正） | 1行＝1レコードで保存する。科目引き当てを削除 |
| `app/services/course_search.rb`（`course_offering_search.rb` から改名） | 保存済みの講義の絞り込み |
| `app/controllers/course_registrations_controller.rb`（修正） | 一覧の参照先を `Course` に |
| `app/controllers/timetable_uploads_controller.rb`（修正） | `:course_choice` の受け取りと保存通知の文面 |
| `app/views/course_registrations/index.html.erb`（修正） | 表の値の参照先 |
| `app/views/timetable_uploads/show.html.erb`（修正） | 「既存の講義と被っています」の欄を削除 |
| `app/helpers/timetable_uploads_helper.rb`（修正） | `course_choice_options` を削除 |
| `test/models/course_test.rb`（`course_offering_test.rb` から改名） | 統合テーブルの検証と制約 |
| `test/services/course_search_test.rb`（`course_offering_search_test.rb` から改名） | 絞り込み |
| `test/lib/timetable_import/importer_test.rb`（修正） | 取り込みの保存 |
| `test/controllers/course_registrations_test.rb`（修正） | 画面の流れ |
| `test/services/graduation_assessment_test.rb`（修正） | 重複算入しないこと |
| `docs/database-design.md` / `docs/db-er-diagram.mmd` / `README.md`（修正） | ドキュメント |

**タスクの進み方について：** これは1つの不可分なスキーマ変更なので、Task 1 と Task 2 の途中では `bin/rails test` 全体が赤になる。各タスクの検証ステップで「このタスクで緑にするテスト」を明示しているので、そこだけを走らせる。全体が緑になるのは Task 3 の最後。

---

### Task 1: 統合テーブルへの移行（migration とモデル）

**Files:**
- Create: `db/migrate/20261124000000_merge_course_offerings_into_courses.rb`
- Modify: `app/models/course.rb`
- Modify: `app/models/department.rb:7`（`has_many :course_offerings`）
- Delete: `app/models/course_offering.rb`
- Modify: `db/schema.rb`（`db:migrate` が生成）
- Test: `test/models/course_test.rb`（`test/models/course_offering_test.rb` を `git mv` して書き換え）

**Interfaces:**
- Consumes: `TimetableImport::Values::SEMESTERS` / `REQUIREMENT_TYPES` / `WEEKDAYS`
- Produces:
  - `Course::SEMESTERS` / `Course::REQUIREMENT_TYPES` / `Course::WEEKDAYS`（`CourseOffering` から移す定数）
  - `Course.offered` … `where.not(lecture_code: nil)` を返すscope
  - `Course#department` … `belongs_to :department, optional: true`
  - `Department#courses` … `has_many :courses, dependent: :restrict_with_error`

- [ ] **Step 1: 失敗するテストを書く**

`test/models/course_offering_test.rb` を `git mv` で `test/models/course_test.rb` にし、中身を書き換える。`build_course` は統合後の開講1件ぶん（`name` / `credits` / `department` / `semester` / `year` / `lecture_code`）を既定にするヘルパー。

```ruby
test '同じ年度・学期で講義コードは重複できない'
  # build_course(lecture_code: 'k001').save! のあと、同じ値は valid? が false

test '年度が違えば同じ講義コードを登録できる'
  # year: 2026 で保存したあと、year: 2027 が valid?

test '講義コードがあるのに学期が無い行はDBが拒否する'
  # Course.new(name: 'x', lecture_code: 'k001', semester: nil) を
  # insert_all! などで検証を迂回して入れると ActiveRecord::StatementInvalid

test '便覧由来の科目は開講の列がすべて空でよい'
  # Course.new(curriculum_key: 'k', name: 'x', credits: 2) が valid? で、
  # 保存後の grade_years と periods が []

test '年度・学科は空でもよい'
  # build_course(year: nil, department: nil) が valid?

test '必修選択・曜日は選択肢の外を拒否する'
  # requirement_type: '必' / weekday: '日' が valid? false

test 'offered は講義コードを持つ行だけを返す'
  # 便覧由来の行と開講の行を1つずつ作り、Course.offered が後者だけ
```

移行そのもの（Review Focus 1・2）は Step 6 で実データの形を作って確かめる。

- [ ] **Step 2: テストを走らせて失敗を確かめる**

Run: `bin/rails test test/models/course_test.rb`
Expected: FAIL（`Course` に `lecture_code` などの列が無い）

- [ ] **Step 3: migration を書く**

`db/migrate/20261124000000_merge_course_offerings_into_courses.rb`。`up` / `down` を手で書く（`change` では戻せない）。

`up` の順番：

1. `remove_reference :timetable_upload_rows, :course, foreign_key: true` と `remove_column :timetable_upload_rows, :register_as_new`。**行は消さない**（確認中の取り込みを続けられるようにするため。理由をコメントに書く）
2. `courses` に `year` / `semester` / `lecture_code` / `requirement_type` / `grade_years` / `weekday` / `periods` / `term_type` / `department_id` を足す（この時点ではindexもcheck制約も付けない）。`department_id` は `add_reference ... foreign_key: true`
3. 開講行を移す。次の2つのSQLを `execute` で流す（順番に意味がある）

```sql
-- その科目の最初の開講行で、科目行が curriculum_key を持たないもの → その場で更新する。
-- id が変わらないので student_courses / planned_courses の参照が切れない。
UPDATE courses c
   SET year = o.year, semester = o.semester, lecture_code = o.lecture_code,
       requirement_type = o.requirement_type, grade_years = o.grade_years,
       weekday = o.weekday, periods = o.periods, term_type = o.term_type,
       department_id = o.department_id, updated_at = o.updated_at
  FROM (SELECT DISTINCT ON (course_id) * FROM course_offerings ORDER BY course_id, id) o
 WHERE c.id = o.course_id
   AND c.curriculum_key IS NULL;

-- 残り（2件目以降の開講、または科目行が curriculum_key を持つもの）→ 新しい行にする。
-- curriculum_key はコピーしない。コピーすると一意indexに当たって移行が途中で死ぬうえ、
-- 便覧の科目行に開講情報が載ると、同じ科目を学期ごとに持てなくなる。
INSERT INTO courses (course_number, name, credits, year, semester, lecture_code,
                     requirement_type, grade_years, weekday, periods, term_type,
                     department_id, created_at, updated_at)
SELECT c.course_number, c.name, c.credits, o.year, o.semester, o.lecture_code,
       o.requirement_type, o.grade_years, o.weekday, o.periods, o.term_type,
       o.department_id, o.created_at, o.updated_at
  FROM course_offerings o
  JOIN courses c ON c.id = o.course_id
 WHERE c.curriculum_key IS NOT NULL
    OR o.id <> (SELECT min(id) FROM course_offerings WHERE course_id = o.course_id);
```

4. 用済みの科目行を消す。`curriculum_key` が無く `lecture_code` も無く、`student_courses` / `planned_courses` から参照されていない行。消さずに残った行があれば `say` で件数を知らせる（既存の `20261027100000` の `say` と同じ調子で）

```sql
DELETE FROM courses
 WHERE curriculum_key IS NULL
   AND lecture_code IS NULL
   AND id NOT IN (SELECT course_id FROM student_courses)
   AND id NOT IN (SELECT course_id FROM planned_courses);
```

5. index と check制約を足す（Global Constraints の名前と条件のとおり）。データを直したあとに付けるので、移行漏れがあればここで止まる
6. `drop_table :course_offerings`

`down`：`course_offerings` を `20261016100000` + `20261027100000` の形で作り直し、`courses` の `offered` 相当の行を「科目行＋開講行」に分けて戻す。`timetable_upload_rows` に `course_id`（`foreign_key: true`）と `register_as_new`（`default: false, null: false`）を戻す（値は復元できない）。統合前の「1科目に複数学期の開講」というまとまりは戻らず開講1件＝科目1行になることを `say` で知らせる。

- [ ] **Step 4: モデルを直す**

`app/models/course.rb`：
- `CourseOffering` から `SEMESTERS` / `REQUIREMENT_TYPES` / `WEEKDAYS` を移す
- `belongs_to :department, optional: true` を足し、`has_many :course_offerings` を消す
- `scope :offered, -> { where.not(lecture_code: nil) }`
- 検証を足す：`semester` は `SEMESTERS` に含まれる（`allow_nil`）／`lecture_code` があるときは `semester` 必須／`lecture_code` は `scope: %i[year semester]` で一意（`allow_nil`）／`requirement_type` と `weekday` は選択肢に含まれる（`allow_nil`）／`year` は1〜9999の整数（`allow_nil`）
- `year` / `department_id` をNULL可にしている理由（便覧由来の行のため、取り込み画面では必須）をコメントに残す。`course_offering.rb` にあった同じ趣旨のコメントを引き継ぐ

`app/models/department.rb`：`has_many :course_offerings, dependent: :restrict_with_error` を `has_many :courses, dependent: :restrict_with_error` にする。

`app/models/course_offering.rb` を `git rm` する。

- [ ] **Step 5: migration を流してテストを通す**

Run: `bin/rails db:migrate && bin/rails test test/models/course_test.rb`
Expected: migration が通り、`db/schema.rb` が更新され、`test/models/course_test.rb` が PASS

このタスクの時点で `test/lib/timetable_import/importer_test.rb` / `test/controllers/course_registrations_test.rb` / `test/services/course_offering_search_test.rb` / `test/models/timetable_upload_test.rb` は赤になる（Task 2・3 で直す）。

- [ ] **Step 6: 移行を実データの形で手で確かめる（Review Focus 1・2）**

`bin/rails db:rollback` で戻したあと、`bin/rails runner` で次の3つを作り、`db:migrate` を流して結果を確かめる。

1. `curriculum_key` を持つ科目1件に `course_offerings` 1件 → 移行後、便覧の行（キーあり・開講列が空）と開講の行（キーなし）の2行になり、キーの重複が無いこと
2. `curriculum_key` を持たない科目1件に `course_offerings` 2件（学期違い）＋その科目を指す `planned_courses` 1件 → 移行後、`planned_courses.course_id` が存在する行を指しており、その科目が2行になっていること
3. `curriculum_key` も開講行も無く、どこからも参照されていない科目1件 → 移行後に消えていること

確かめたらもう一度 `db:rollback` → `db:migrate` で、`down` が通ることも見る。

- [ ] **Step 7: コミット**

```bash
git add -A db app/models test/models/course_test.rb
git commit
```

`feat: coursesとcourse_offeringsを1つのテーブルに統合する`

---

### Task 2: 取り込みを統合テーブルに保存する

科目の引き当て（「既存の講義として扱う／別の講義として登録」）を丸ごと削除する。

**Files:**
- Modify: `lib/timetable_import/importer.rb`
- Modify: `app/models/timetable_upload_row.rb`
- Modify: `app/models/timetable_upload.rb:36`（`assign_default_course_choice` の呼び出し）
- Modify: `app/controllers/timetable_uploads_controller.rb`（`submitted_edits` の `:course_choice`、`commit` の通知文）
- Modify: `app/views/timetable_uploads/show.html.erb:60-70`（被りの欄）
- Modify: `app/helpers/timetable_uploads_helper.rb`（`course_choice_options`）
- Test: `test/lib/timetable_import/importer_test.rb`
- Test: `test/controllers/course_registrations_test.rb:550-670`（被りの選択に関するテストの削除だけ。新しいテストは Task 3）

**Interfaces:**
- Consumes: `Course`（Task 1）、`Course.offered`
- Produces:
  - `TimetableImport::Importer::Result` … `Struct.new(:errors, :created, :updated, :unchanged, :applied, keyword_init: true)`。`created_courses` / `created_offerings` / `updated_offerings` / `unchanged_offerings` は無くなる
  - `TimetableImport::Importer::RowAttributes#course_attributes` … 1行ぶんの `Course` の属性（科目番号・科目名・単位・学期・講義コード・必修選択・受講年次・曜日・時限・開講区分）を返す。年度と学科は `Importer` が足す

- [ ] **Step 1: 失敗するテストを書く**

`test/lib/timetable_import/importer_test.rb` を統合後の形に書き換える。

消すテスト：`a registered course with the same name and number is never merged automatically` / `choosing new registers a separate course even if the name and number exist` / `a course without a number is not matched to anything and stays separate` / `a chosen course that no longer exists is an error` / `credit mismatch with a chosen course is an error, not an overwrite` / `rows with the same name and number in one import share one new course`。`linked_row` ヘルパーも消す。

残すテストは件数の期待値を `created` / `updated` / `unchanged` に直し、`CourseOffering` の参照を `Course.offered` にする。足すテスト：

```ruby
test '同じ科目番号・科目名の講義が登録済みでも、止まらず別の行になる'
  # Course.create!(course_number: '工共100', name: '工学基礎演習', credits: 2, …) を
  # 講義コード違いで先に入れてから importer([row]).call(apply: true)
  # → result.ok? / created == 1 / Course.offered.count == 2

test '同じPDFの中で同じ科目番号・科目名の行は、講義コードごとに別の行になる'
  # row と row('講義コード' => '610000072') の2行 → created == 2

test '再取り込みで科目名・単位が変わると、その行が更新される'
  # 保存後に row('科目名' => '工学基礎演習A', '単位' => '3') を流す
  # → updated == 1、Course.offered.sole の name と credits が新しい値

test '1行が科目と開講の両方の値を持つ'
  # 保存後の Course.offered.sole で course_number / credits / semester /
  # lecture_code / grade_years / periods / requirement_type / weekday / term_type
```

`test/controllers/course_registrations_test.rb` から、被りの選択に関するテストを消す（`course_choice` を送る／`register_as_new` を確かめる／候補のセレクトを `assert_select` する 550〜670行あたり）。このファイルの残りは Task 3 で直す。

- [ ] **Step 2: テストを走らせて失敗を確かめる**

Run: `bin/rails test test/lib/timetable_import/importer_test.rb`
Expected: FAIL（`CourseOffering` が無い、`Result` に `created` が無い）

- [ ] **Step 3: `Importer` を書き換える**

- `Result` を上記の形にする
- `resolve_course` / `linked_course` / `create_course` / `same_course_registered?` / `UNRESOLVED_MESSAGE` / `save_offering` / `find_offering` を削除し、`import_row` が `Course.find_or_initialize_by(year: @year, semester: attrs.semester, lecture_code: attrs.lecture_code)` に `attrs.course_attributes` と `department_id: @department_id` を入れて保存する形にまとめる
- 「講義コード◯◯は別の科目で登録済みです」のエラーを削除（1行に科目と開講が同居するので、同じ講義コードの行は更新になる）
- `RowAttributes` から `course_id` / `register_as_new` / `parse_course_id` を削除し、`offering_attributes` を `course_attributes` に替えて科目番号・科目名・単位も含める
- クラスのコメントを書き直す。引き当てのキーが `(年度, 学期, 講義コード)` だけであること、学科をキーに入れない理由（既存コメントを引き継ぐ）、科目の引き当てが無くなったことを書く

- [ ] **Step 4: 取り込み行と画面から選択を消す**

- `app/models/timetable_upload_row.rb`：`belongs_to :course`、`course_candidates`、`course_choice_resolved?`、`default_course`、`assign_default_course_choice`、`course_choice`、`apply_course_choice`、`credits_mismatch_message` を削除。`apply_edit` は編集値の反映だけにする（科目番号・科目名を直したときに選択を捨てる分岐も不要）。`problems` は `RowAttributes#errors` だけを返す。`importer_values` から `既存講義ID` と `新規登録` を削除
- `app/models/timetable_upload.rb`：`build_from_pdf` の `upload_row.assign_default_course_choice` を削除
- `app/views/timetable_uploads/show.html.erb`：「既存の講義と被っています」の `div`（選択欄ごと）と、そのための `candidates` の算出を削除
- `app/helpers/timetable_uploads_helper.rb`：`course_choice_options` を削除
- `app/controllers/timetable_uploads_controller.rb`：`submitted_edits` の `permit` から `:course_choice` を外す。`commit` の通知文を `"保存しました。講義の新規#{result.created}件・更新#{result.updated}件・変更なし#{result.unchanged}件。"` にする

- [ ] **Step 5: テストを通す**

Run: `bin/rails test test/lib/timetable_import/importer_test.rb`
Expected: PASS

- [ ] **Step 6: 確認中の取り込みが生き残ることを確かめる（Review Focus 3）**

`bin/rails db:rollback` で Task 1 の migration を戻し、`bin/rails runner` で `TimetableUpload` を1件（行つき、一部 `confirmed`）作る。`bin/rails db:migrate` を流したあと、`bin/rails runner` でその取り込みの行が残っていること、`problems` が例外を出さないこと、`preview` が件数を返すことを確かめる。

- [ ] **Step 7: コミット**

```bash
git add -A lib app/models app/views app/helpers app/controllers test/lib test/models
git commit
```

`refactor: 取り込みから科目の引き当てをなくし、1行をそのまま保存する`

---

### Task 3: 講義の一覧を統合テーブルから引く

**Files:**
- Modify+Rename: `app/services/course_offering_search.rb` → `app/services/course_search.rb`
- Modify: `app/controllers/course_registrations_controller.rb`
- Modify: `app/views/course_registrations/index.html.erb:92-120`（案内の出し分けと表の値）
- Test: `test/services/course_search_test.rb`（`course_offering_search_test.rb` を `git mv`）
- Test: `test/controllers/course_registrations_test.rb`（テストの追加と、保存通知の期待値）

**Interfaces:**
- Consumes: `Course`、`Course.offered`（Task 1）、`Importer::Result`（Task 2）
- Produces: `CourseSearch.new(params)` … `#conditions` / `#filtered?` / `#relation` は今と同じ契約。`relation` が返すのは `Course` のリレーション

- [ ] **Step 1: 失敗するテストを書く**

`test/services/course_offering_search_test.rb` を `git mv` で `test/services/course_search_test.rb` にし、`CourseOfferingSearch` を `CourseSearch` に、`create_offering` を `Course.create!` 1回で作る形に書き換える。**期待値は変えない**（並び順、年度NULLが最後、学部・学科・科目番号・講義コード・科目名の絞り込み、LIKEのメタ文字）。

`test/controllers/course_registrations_test.rb` に足すテスト（Review Focus 5）：

```ruby
test '便覧の科目しか無いときは、保存された講義が無い案内を出す'
  # Course.create!(curriculum_key: 'k', name: 'x', credits: 2) だけがある状態で
  # get course_registrations_path → 'まだ保存された講義はありません' を含み、
  # 検索バー（'条件を消す' など）を含まない

test '取り込んだ講義があれば、便覧の科目も一覧に出る'
  # 取り込み1件 + 便覧の科目1件 → 両方の科目名が本文にある
```

被りの選択に関するテストは Task 2 で消してある。保存後の通知文を確かめている箇所を Task 2 の文面（`講義の新規N件・更新N件・変更なしN件`）に合わせる。

- [ ] **Step 2: テストを走らせて失敗を確かめる**

Run: `bin/rails test test/services/course_search_test.rb test/controllers/course_registrations_test.rb`
Expected: FAIL（`CourseSearch` が無い）

- [ ] **Step 3: `CourseSearch` を書く**

`app/services/course_search.rb`。`EXACT_KEYS` / `PARTIAL_KEYS` / `KEYS` と `conditions` / `filtered?` はそのまま。`relation` は `Course.includes(department: :faculty)` から始め、並びは `Arel.sql('courses.year DESC NULLS LAST')` → `:semester, :weekday, :periods, :id`。`narrow_by_text` は `joins(:course)` が不要になり、`courses.course_number` / `courses.name` / `courses.lecture_code` に直接当てる。クラスのコメントを統合後の内容に書き直す（`#53` への言及を、便覧由来の行が同居する説明に替える）。

- [ ] **Step 4: コントローラとビューを直す**

`app/controllers/course_registrations_controller.rb`：
- `@search = CourseSearch.new(params)`
- `@offerings` → `@courses`
- `@any_offering` → `@any_course = Course.offered.exists?`（`Course.exists?` にしない理由をコメントに書く。便覧の科目が1件入っただけで案内が消え、空の行だけの表が出てしまうため）
- `@search_years = Course.distinct.order(year: :desc).pluck(:year).compact`

`app/views/course_registrations/index.html.erb`：`@offerings` → `@courses`、`offering.course.course_number` → `course.course_number` など。表の列・見出し・ページ送りは変えない。

- [ ] **Step 5: テストを通す**

Run: `bin/rails test`
Expected: PASS（ここで全体が緑に戻る）

- [ ] **Step 6: コミット**

```bash
git add -A app test
git commit
```

`refactor: 講義の一覧を統合したcoursesから引く`

---

### Task 4: 同じ科目を重複して算入しないことを固定する

**Files:**
- Test: `test/services/graduation_assessment_test.rb`

**Interfaces:**
- Consumes: `GraduationAssessment#call(completed:, registered:, planned:, unresolved:)`

- [ ] **Step 1: テストを書く**

同じ `key` のエントリが複数来たときの2つの枝を固定する。既に同趣旨のテストがあれば足さず、無い枝だけ足す。

```ruby
test '同じ科目の記録が複数あっても、単位が一致すれば算入は1回'
  # completed に同じ key・同じ credits のエントリを2件渡し、
  # その科目の算入単位が1件ぶんであること

test '同じ科目の記録で単位が食い違うと、算入せず要確認になる'
  # completed に同じ key で credits が違うエントリを2件渡し、
  # 算入が0で、notes に '同一科目の複数記録' を含む行があること
```

- [ ] **Step 2: テストを走らせる**

Run: `bin/rails test test/services/graduation_assessment_test.rb`
Expected: PASS（判定側は既にこうなっているので、実装の変更は不要。落ちたら実装を直す前に期待値が仕様どおりか設計書で確かめる）

- [ ] **Step 3: コミット**

```bash
git add test/services/graduation_assessment_test.rb
git commit
```

`test: 同じ科目の複数記録を二重に算入しないことを固定する`

---

### Task 5: ドキュメントを統合後の形に直す

**Files:**
- Modify: `docs/database-design.md`
- Modify: `docs/db-er-diagram.mmd`
- Modify: `README.md`（「講義登録」の節）

- [ ] **Step 1: `docs/database-design.md` を直す**

- Mermaid のER図から `courses ||--o{ course_offerings` と `departments ||--o{ course_offerings` を消し、`departments ||--o{ courses : "開講学科"` を足す
- 表の `courses` の行を書き直す：便覧の科目（`curriculum_key` を持ち、開講の列が空）と、授業時間配当表の開講1件（`(年度, 学期, 講義コード)` で一意）が同じテーブルに入ること、`courses_offering_pair` でその2種類しかないことを示していること
- 表から `course_offerings` の行を消す
- `timetable_uploads / timetable_upload_rows` の行から、既存の講義の選択（`course_id` / `register_as_new` / 被りの既定選択）の説明を消す
- 「科目・履修の同一性」の節に、講義の同一性が `(年度, 学期, 講義コード)` で決まること、履修・計画が指すのは `curriculum_key` を持つ行だけであることを足す

- [ ] **Step 2: `docs/db-er-diagram.mmd` を直す**

同じ内容に合わせる。`course_offerings` のブロックを消し、`courses` のブロックに開講の列を足す。あわせて `departments ||--o{ students : "現在の所属"` を `programs ||--o{ students` に直し、`students` のブロックの `department_id` を `program_id` にする（いまのschemaとずれている）。`docs/db-er-diagram.png` は再生成しない。

- [ ] **Step 3: `README.md` の「講義登録」の節を直す**

- 手順3（被りの選択）を削除し、手順4を3に繰り上げる
- 「`courses` と `course_offerings` に入る」を `courses` だけにする
- 節の末尾「科目番号・科目名・単位は `courses`、…は `course_offerings` に入る」を、1件の講義が `courses` の1行に入る説明に替える

- [ ] **Step 4: 全体を確かめる**

Run: `bin/rails test && bundle exec rubocop`
Expected: どちらも PASS

- [ ] **Step 5: コミット**

```bash
git add docs README.md
git commit
```

`docs: 統合後のcoursesに合わせてDB設計とREADMEを直す`

---

## 完了の条件

- `bin/rails test` と `bundle exec rubocop` が通る
- `bin/rails db:migrate` / `db:rollback` / `db:migrate` が通る
- `course_offerings` テーブルとモデルが無い
- 確認画面に「既存の講義と被っています」の欄が無い
- `docs/database-design.md` / `docs/db-er-diagram.mmd` / `README.md` に `course_offerings` が出てこない
