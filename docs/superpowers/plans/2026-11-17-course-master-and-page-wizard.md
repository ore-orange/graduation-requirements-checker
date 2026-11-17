# 科目名簿への移行と、手順①の作り直し 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 便覧が持つ科目を「番号から区分が決まらないもの」だけにし、学生に見せる科目は `courses` テーブルから描き、手順①を1ページずつの確認に作り直す。

**Architecture:** 絞り込み（`CourseFilter`）は読み取りの統合点（`DraftMerge#courses`）に置き、番号パターンの候補（`CategoryInference#suggestions`）は人が押して採用する。学生に見せる科目は `CourseDirectory` が1か所で答え、判定（`GraduationAssessment`）はこの名簿を使わず今までどおり `Catalogue` で動く。手順①は Stimulus で1ページずつ見せ、保存と読み取りを1回の操作につなぐ。

**Tech Stack:** Ruby 3.4 / Rails 8 / Hotwire (Turbo + Stimulus) / Tailwind / PostgreSQL 17 / Minitest

**Spec:** [docs/superpowers/specs/2026-11-17-course-master-and-page-wizard-design.md](../specs/2026-11-17-course-master-and-page-wizard-design.md)

## Global Constraints

- 判定の数式を変えない。同じ便覧・同じ履修なら、学生に出る判定結果は前後で同じ。
- `test/fixtures/files/graduation_golden_2024.json` は変わらない。変わったら実装が間違っている。
- 「触らずに保存しても、文書が1バイトも変わらず、人が確認した印も付かない」を壊さない。
- 公開済みの便覧の形（`PublishedDocument` が通す欄）を減らさない。484件を持つ既存の便覧も、そのまま読めて判定できる。
- `config/curricula/intelligent_informatics/2024.json`・`2025.json` の `courses` は減らさない。
- 画面にアプリ内部の識別子（区分キー・規則 id・行 id・役割キー）を出さない。
- 新しい gem を足さない。
- テストは `bin/rails test`、全体は `bin/ci`。日本語のテスト名を使う（既存に倣う）。

## Review Focus

仕様が含意するが、各タスクの本筋のテストでは触らない入力。各行のテストを、そのコードを持つタスクに足してある。

1. **科目番号が空の科目** — 絞り込みが落としてはいけない（番号が無ければ区分を決めようがない）。Task 1。
2. **パターンが決めた区分と、AIが読んだ区分が食い違う科目** — 落とさず残す。これが「例外」の証拠。Task 1。
3. **同じ番号で名前の違う `Course` が2行ある** — 名簿は2件とも出し、「便覧から選択」は `Course#id` で1行に決める。Task 8・9。
4. **`categories` が空の下書きで名簿を引く** — 便覧を1ページも読んでいない下書き。空を返し、例外にしない。Task 8。
5. **ページ画像が無い下書きで手順①を開く** — 手でページ数を指定した下書き。壊れた画像を並べず、テキストの冒頭を代わりに出す。Task 11。

## File Structure

**新規**

| ファイル | 責任 |
|---|---|
| `app/services/curriculum_import/course_filter.rb` | 読んだ科目1件を便覧に残すか決める。純粋な判定のみ |
| `app/services/course_directory.rb` | 「この便覧のこの区分にはどの科目があるか」に答える。`Course` と便覧の登録を合わせる |
| `app/javascript/controllers/page_wizard_controller.js` | 手順①の1ページずつの表示・3択・一覧 |
| `db/course_master.json` | 科目名簿の種（`number`・`name`・`credits`） |
| `lib/tasks/course_master.rake` | 既存の便覧JSONから `db/course_master.json` を作る1回限りのタスク |

**変更**

| ファイル | 変更の中身 |
|---|---|
| `app/services/curriculum_import/draft_merge.rb` | `#courses` が `CourseFilter` と重複外しを通す |
| `app/services/curriculum_import/category_inference.rb` | `#suggestions` を足す |
| `app/services/curriculum_import/requirements_edit.rb` | パターン候補の採用を受ける |
| `app/services/curriculum_import/requirements_review.rb` | 候補を画面へ渡す |
| `app/services/curriculum_import/courses_review.rb` | 「番号で決まる科目を外す」の対象と件数 |
| `app/controllers/curricula_controller.rb` | 絞り込みの実行、`update` の Turbo Stream 応答 |
| `app/services/curriculum_import/validation/rule_checks.rb` | 0件の扱い、文面の和名化 |
| `app/services/curriculum_import/validation/display_checks.rb` | 同上 |
| `app/services/curriculum_import/validation/document_checks.rb` | 同上 |
| `app/services/curriculum_import/validation/input.rb` | 規則・行の人が読める名前を返す口 |
| `app/views/curricula/_pages.html.erb`・`_page_row.html.erb` | 1ページずつの表示と一覧に作り直す |
| `app/javascript/controllers/read_pages_controller.js` | 保存から読み取りへ続ける、進捗 |
| `app/views/plans/_add_course_box.html.erb`・`show.html.erb` | 名簿から描く、`Course#id` を送る |
| `app/controllers/plans_controller.rb` | `@catalogue` を名簿から作る |
| `app/controllers/plan_courses_controller.rb` | `Course#id` を受ける |
| `app/helpers/requirements_helper.rb` | `courses_by_category` を名簿から作る |
| `app/services/demo_data.rb` | `db/course_master.json` から `Course` を作る |

---

### Task 1: `CourseFilter` — 便覧に残す科目を決める

**Files:**
- Create: `app/services/curriculum_import/number_patterns.rb`
- Create: `app/services/curriculum_import/course_filter.rb`
- Test: `test/services/curriculum_import/course_filter_test.rb`

**Interfaces:**
- Consumes: `GraduationAssessment::Catalogue#pattern_category_for(number)`、`CurriculumImport::CourseEdit.confirmed?(course)`
- Produces:
  - `CurriculumImport::NumberPatterns.new(categories)` / `#category_for(number) -> String | nil`
  - `CourseFilter.new(document)` / `#keep?(course) -> Boolean` / `#partition(courses) -> [kept, dropped]` / `#drop_summary(dropped) -> String`

`document` は便覧の文書（Hash）。`Catalogue` は壊れた下書きで例外を投げるので、下書きの途中では使えない。`Catalogue#pattern_category_for` と同じ規則（百の位の鍵 → 接頭辞の鍵）を `NumberPatterns` に切り出し、`CourseFilter` と Task 9 の `CourseDirectory` が両方これを使う。`Catalogue` 側は変えない（判定の経路に触らない）。

- [ ] **Step 1: 失敗するテストを書く**

`NumberPatterns` のテストは `course_filter_test.rb` に同居させる（`#category_for` が百の位を接頭辞より先に見ること、どちらにも当たらなければ `nil` を返すこと）。

```ruby
# test/services/curriculum_import/course_filter_test.rb
DOCUMENT = {
  'categories' => [
    { 'key' => 'humanities', 'label' => '人文系', 'number_patterns' => ['人'] },
    { 'key' => 'advanced', 'label' => '知能情報アドバンスト' }
  ]
}.freeze

test '番号パターンで区分が決まり、読みも一致する科目は残さない' # 人01/humanities -> keep? false
test '番号パターンを持たない区分の科目は残す'                  # 知能301/advanced -> true
test '科目番号が空の科目は残す'                               # number nil -> true
test 'パターンが決めた区分と読みが違う科目は残す'               # 人01/advanced -> true
test '必修の科目は、パターンで決まっても残す'                   # required true -> true
test '役割を持つ科目は、パターンで決まっても残す'               # roles ['x'] -> true
test '承認が要る科目は、パターンで決まっても残す'               # requires_approval true -> true
test '選べない科目は、パターンで決まっても残す'                 # selectable false -> true
test 'AIが要確認とした科目は、パターンで決まっても残す'          # review_reason '...' -> true
test '人が確認した科目は、パターンで決まっても残す'              # confirmed -> true
test '人が手で足した科目は、パターンで決まっても残す'            # added_by_hand true -> true
test 'partition は残すものと落とすものに分ける'
test 'drop_summary は件数と区分ごとの内訳を1文で返す'
```

`drop_summary` の期待値: `'番号から区分が決まる科目2件は、登録しませんでした(人文系2件)。区分の科目番号のパターンで数えます。'`

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/services/curriculum_import/course_filter_test.rb`
Expected: FAIL（`NameError: uninitialized constant CourseFilter`）

- [ ] **Step 3: `CourseFilter` を実装する**

`keep?` は仕様 §2 の条件を素直に並べる。`confirmed?` は `CourseEdit.confirmed?` に委ねる。承認の注記が当たっている科目は `requires_approval` が真になっているので、別の条件は要らない。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bin/rails test test/services/curriculum_import/course_filter_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add app/services/curriculum_import/number_patterns.rb app/services/curriculum_import/course_filter.rb test/services/curriculum_import/course_filter_test.rb
git commit -m "feat: 便覧に残す科目を決める絞り込みを足す"
```

---

### Task 2: 読み取りが、絞り込みと重複外しを通る

**Files:**
- Modify: `app/services/curriculum_import/draft_merge.rb`（`#courses`、68〜84行あたり）
- Test: `test/services/curriculum_import/draft_merge_filter_test.rb`（新規）

**Interfaces:**
- Consumes: Task 1 の `CourseFilter#keep?` / `#drop_summary`
- Produces: `DraftMerge#warnings` に、落とした件数と重複の件数の文が入る

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '番号パターンで決まる科目は、読んでも文書に入らない'
test '落とした件数と内訳が warnings に入る'
test '同じ科目番号・科目名の科目は、2回読んでも1件のまま'
test '同じ科目番号で名前が違う科目は、2件とも入る'   # 読み違いなので突き合わせに任せる
test '外した重複の件数が warnings に入る'
test '番号の全角・空白の違いだけの重複も外す'        # CourseNumber.normalize と squish で比べる
test 'パターンを持たない区分だけの便覧では、1件も落ちない'
```

重複の判定は、`human_owned?` を抜けた行に対して、**いま文書にある科目**と「`CourseNumber.normalize` した番号が等しく、かつ `squish` した名前が等しい」ことで行う。同じ読み取りの中で足した行も比較の対象に含める。

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/services/curriculum_import/draft_merge_filter_test.rb`
Expected: FAIL

- [ ] **Step 3: `DraftMerge#courses` に2つの関門を足す**

`human_owned?(row, held, removed)` で飛ばしたあと、`duplicate?(row, courses)` と `CourseFilter#keep?` の順に通す。落とした行は数えておき、`@warnings` に `drop_summary` と重複の文を足す。`contributed`（このページが足した key の記録）には、入れた科目だけを載せる。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bin/rails test test/services/curriculum_import/draft_merge_filter_test.rb test/services/curriculum_import/courses_protection_test.rb test/services/curriculum_import/read_page_test.rb`
Expected: PASS

- [ ] **Step 5: 全体のテスト**

Run: `bin/rails test`
Expected: PASS（golden を含む）

- [ ] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: 科目表の読み取りで、番号で決まる科目と重複を外す"
```

---

### Task 3: 番号パターンの候補を出す

**Files:**
- Modify: `app/services/curriculum_import/category_inference.rb`
- Test: `test/services/curriculum_import/category_inference_test.rb`

**Interfaces:**
- Produces: `CategoryInference#suggestions -> { 区分キー => [パターン文字列] }`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '百の位の鍵が1区分にしか現れず、3件以上あれば候補になる'
test '複数の区分にまたがる鍵は候補にならない'
test '根拠が2件以下の鍵は候補にならない'
test '百の位で候補が出た区分には、接頭辞だけの鍵を重ねない'
test '2024年度の便覧から、先・知能4・知能9・機械9・エネ9・電気9・電情9・社基9・建築9 が候補になる'
test '2024年度の便覧から、転・全教4・情0・情1 は候補にならない'  # 根拠が3件に届かない
```

最後の2つは `config/curricula/intelligent_informatics/2024.json` を読んで確かめる。

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/services/curriculum_import/category_inference_test.rb`
Expected: FAIL（`NoMethodError: suggestions`）

- [ ] **Step 3: `#suggestions` を実装する**

既にある `@by_hundreds` / `@by_prefix` を使う。`MIN_SUPPORT`（3）を満たし、1区分にしか現れない鍵を集める。接頭辞の鍵は、その接頭辞を持つ百の位の鍵がすべて同じ区分で、かつその区分がまだ候補を持たないときだけ足す。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bin/rails test test/services/curriculum_import/category_inference_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 科目表から、区分の科目番号パターンの候補を出す"
```

---

### Task 4: 候補を画面に出し、人が押して採用する

**Files:**
- Modify: `app/services/curriculum_import/requirements_review.rb`、`app/services/curriculum_import/requirements_edit.rb`、`app/views/curricula/_requirements_categories.html.erb`
- Test: `test/services/curriculum_import/requirements_edit/category_patterns_test.rb`（新規）、`test/controllers/curricula_controller_test.rb`

**Interfaces:**
- Consumes: Task 3 の `CategoryInference#suggestions`、Task 1 の `CourseFilter#partition`
- Produces: `RequirementsReview#pattern_suggestions_for(category_key) -> [String]`。`PATCH /curricula/:id` が `adopt_patterns[<区分キー>]=1` を受ける

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# category_patterns_test.rb
test '候補を採用すると、その区分の number_patterns に入る'
test '候補を採用すると、その区分の confirmed が立つ'    # 人が押した値なので、読み直しで上書きしない
test '採用で条件に当たるようになった科目は、文書から外れる'
test '確認済みの科目も、採用のときは外れる'            # 読み取り時の絞り込みとは違う(仕様 R1)
test '既にパターンを持つ区分には、候補を出さない'
test '採用した件数が、保存の知らせに出る'
```

```ruby
# curricula_controller_test.rb
test '区分の欄に、科目番号パターンの候補が出る'
test '候補を採用すると、外した件数を知らせる'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/services/curriculum_import/requirements_edit/category_patterns_test.rb`
Expected: FAIL

- [ ] **Step 3: presenter と編集に口を足す**

`RequirementsReview#pattern_suggestions_for` は、`CategoryInference.new(document['courses']).suggestions` から、その区分ぶんを返す。既に `number_patterns` を持つ区分には空を返す。
`RequirementsEdit` は `adopt_patterns` を受け、候補を `number_patterns` に入れ、`confirmed` を立て、そのあと `CourseFilter#partition` で文書の `courses` を絞る。走るのは `apply_sections` の最後（持ち主からの書き戻しのあと）。

- [ ] **Step 4: 区分の欄に候補を出す**

`_requirements_categories.html.erb` の `details`（「この区分を直す」）の中に、候補があるときだけ出す。

```
科目番号のパターンの候補: 知能4 ・ 知能9
[この候補を使う]   ← 押すと、当たる274件(うち確認済み18件)を便覧から外します
```

チェックボックス `adopt_patterns[<区分キー>]` にし、要件表の保存と同じ送信に乗せる。確認は `data-turbo-confirm` ではなく、件数をラベルに出して見せる（保存はまとめて1回なので、押した時点では外れない）。

- [ ] **Step 5: テストが通ることを確かめる**

Run: `bin/rails test test/services/curriculum_import/ test/controllers/curricula_controller_test.rb`
Expected: PASS

- [ ] **Step 6: 全体のテストとコミット**

```bash
bin/rails test && git add -A && git commit -m "feat: 区分の科目番号パターンを候補から採用できるようにする"
```

---

### Task 5: 既にある下書きからも、番号で決まる科目を外せる

**Files:**
- Modify: `app/services/curriculum_import/courses_review.rb`、`app/views/curricula/_courses_review.html.erb`、`app/controllers/curricula_controller.rb`、`config/routes.rb`
- Test: `test/controllers/curricula_controller_test.rb`

**Interfaces:**
- Consumes: Task 1 の `CourseFilter#partition`
- Produces: `POST /curricula/:id/filter_courses`。`CoursesReview#droppable_count -> Integer`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '外せる科目があるとき、③の節にボタンと件数が出る'
test '外せる科目が無いとき、ボタンを出さない'
test '押すと、条件に当たる科目が文書から外れる'
test '公開済みの便覧では断る'
test '複製した下書き(全件確認済み)でも外れる'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/controllers/curricula_controller_test.rb`
Expected: FAIL

- [ ] **Step 3: ルートとアクションを足す**

`curricula_controller#filter_courses`。`bulk_confirm_courses` と同じ形（`with_lock` の中で公開済みを確かめ、素直に画面を開き直す）。外した件数を `notice` に出す。

- [ ] **Step 4: ③の節に置く**

`_courses_review.html.erb` の見出しの下、`courses_summary` の横。

```
[番号で決まる科目を外す(274科目)]   番号から区分が決まり、読みとも一致する科目です。うち18科目は確認済みです。
```

`data-turbo-confirm` で件数を見せてから実行する。

- [ ] **Step 5: テストが通ることを確かめる**

Run: `bin/rails test test/controllers/curricula_controller_test.rb`
Expected: PASS

- [ ] **Step 6: 全体のテストとコミット**

```bash
bin/rails test && git add -A && git commit -m "feat: 下書きから、番号で決まる科目をまとめて外せるようにする"
```

---

### Task 6: 絞り込みで判定が変わらないことを、テストで押さえる

**Files:**
- Create: `test/services/graduation_assessment_filtered_test.rb`
- Modify: `lib/graduation_golden.rb`（ケースから履修を作る口を取り出す）

**Interfaces:**
- Consumes: Task 1 の `CourseFilter`、Task 3 の `CategoryInference#suggestions`
- Produces: なし（テストのみ）

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# 絞り込み前の2024年度の便覧と、候補をすべて採用して絞り込んだ便覧で、同じ履修を判定し、結果が一致すること。
test '絞り込んだ便覧でも、2024年度の判定結果が変わらない' do
  full = GraduationGolden.curriculum_document
  filtered = filter_all(full)   # suggestions を number_patterns に入れ、CourseFilter#partition で絞る
  assert_operator filtered.fetch('courses').size, :<, 150

  GraduationGolden.cases(full).each do |name, arguments|
    expected = GraduationAssessment.new(curriculum: full).call(**rekey(arguments, full))
    actual   = GraduationAssessment.new(curriculum: filtered).call(**rekey(arguments, filtered))
    assert_equal GraduationGolden.snapshot(expected.actual), GraduationGolden.snapshot(actual.actual), name
    assert_equal GraduationGolden.snapshot(expected.projected), GraduationGolden.snapshot(actual.projected), name
  end
end
```

`rekey(arguments, document)` は、`StudentWorkspace#catalogue_entries` と同じ振り替えを行うヘルパー。履修1件の `number` を見て、その文書に同じ番号の科目があればその `key` を、無ければ `"unmatched:<番号>"` を `key` に入れる。**これが無いと、絞り込んだ文書で `pattern_course` の経路に入らず、テストが本物を測らない。** `GraduationGolden.completed_entry` に `number: course['number']` を足して、ケースが番号を運ぶようにする。

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/services/graduation_assessment_filtered_test.rb`
Expected: FAIL

- [ ] **Step 3: 落ちた差分を読む**

**ここで差が出たら、実装ではなく設計が間違っている。** 差分を読み、何が失われたかを書き出してから直す。`CourseFilter` の残す条件が足りないのか、`pattern_course` が作る合成科目に足りない欄があるのか（`language`・`credits`）を切り分ける。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bin/rails test test/services/graduation_assessment_filtered_test.rb test/services/graduation_assessment_golden_test.rb`
Expected: PASS。golden のフィクスチャは変わっていないこと（`git diff --exit-code test/fixtures/files/graduation_golden_2024.json`）

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "test: 絞り込んだ便覧でも2024年度の判定が変わらないことを固定する"
```

---

### Task 7: 「科目が1件もない」検査を、パターンのある区分に当てない

**Files:**
- Modify: `app/services/curriculum_import/validation/rule_checks.rb:70-74`、`display_checks.rb:103-110`、`document_checks.rb:14`、`validation/input.rb`
- Test: `test/services/curriculum_import/validation_test.rb`

**Interfaces:**
- Produces: `Validation::Input#patterned?(category_key) -> Boolean`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '番号パターンを持つ区分が0件でも、規則の警告を出さない'
test 'パターンも科目も持たない区分だけを指す規則には、いまどおり警告を出す'
test '指す区分のうち1つでもパターンを持てば、警告を出さない'
test '行の区分がパターンを持つなら、0件でも警告を出さない'
test '科目0件でも、数える区分がすべてパターンを持つなら公開を止めない'
test '科目0件で、パターンを持たない数える区分があれば公開を止める'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/services/curriculum_import/validation_test.rb`
Expected: FAIL

- [ ] **Step 3: 3つの検査に条件を足す**

`Input#patterned?(key)` は、`categories` のその区分が空でない `number_patterns` を持つか。
- `rule_checks.rb#without_courses` … 指す区分のいずれかが `patterned?` なら返る。
- `display_checks.rb` の行の検査 … 同じ。
- `document_checks.rb` … `courses` が空でも、`counted_category_keys` がすべて `patterned?` なら止めない。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bin/rails test test/services/curriculum_import/validation_test.rb`
Expected: PASS

- [ ] **Step 5: 全体のテストとコミット**

```bash
bin/rails test && git add -A && git commit -m "fix: 番号パターンを持つ区分の科目0件を、問題として報告しない"
```

---

### Task 8: 突き合わせの指摘から、内部の識別子を消す

**Files:**
- Modify: `app/services/curriculum_import/validation/input.rb`、`rule_checks.rb`、`display_checks.rb`、`app/views/curricula/_requirements_rule_box.html.erb:12`、`_requirements_cards.html.erb:51`、`_requirements_findings.html.erb`
- Test: `test/services/curriculum_import/validation_test.rb`、`test/controllers/curricula_controller_test.rb`

**Interfaces:**
- Produces: `Validation::Input#rule_name(rule) -> String`、`#row_name(row_id) -> String`。指摘の `target` は人が読める文字列、`target_id`（画面のリンク先）を別の欄に持つ

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '規則の指摘の target に、規則の id が出ない'
test '規則に label があれば、それを target に使う'
test 'label が無ければ、型の和名と持ち主の行名を使う'   # 例: 「行「基幹領域：外国語科目」の 区分の合計単位」
test '入れ子の規則は「…の中の条件」と出す'              # options[1] の conditions[1] を出さない
test '区分の一覧を出す文面が、キーではなく和名になる'
test '行の指摘の target に、行の id が出ない'
test '指摘から、画面の該当箇所へのリンクは残る'          # target_id が id を持つ
```

```ruby
# curricula_controller_test.rb
test '決まりの箱に、規則の id が出ない'
test '注釈のカードに、規則の id が出ない'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/services/curriculum_import/validation_test.rb`
Expected: FAIL

- [ ] **Step 3: `Input` に名前の口を足し、文面を直す**

`rule_name` は `rule['label']` → 型の和名（`RequirementsReviewHelper#rule_type_name` と同じ対応表を `Validation` からも引けるところへ出す）→ 持ち主の行・章の `name` の順。
`display_checks.rb:228-229` の `missing.join` / `extra.join` と `rule_checks.rb:74` / `:141` の区分の並びを `category_label` に通す。`display_checks.rb:72` の `(#{category})` を落とす。

- [ ] **Step 4: 指摘と画面のリンクを分ける**

`Findings` が `target`（見せる文字）と `target_id`（`#rule-<id>` などのリンク先）を別に持つ。`_requirements_findings.html.erb` は `target` を出し、`target_id` へリンクする。
`_requirements_rule_box.html.erb:12` のリンクのラベルを「この決まりを直す」に、`_requirements_cards.html.erb:51` の `規則「<id>」` を規則の名前にする。

- [ ] **Step 5: テストが通ることを確かめる**

Run: `bin/rails test test/services/curriculum_import/ test/controllers/curricula_controller_test.rb`
Expected: PASS

- [ ] **Step 6: 全体のテストとコミット**

```bash
bin/rails test && git add -A && git commit -m "fix: 突き合わせの指摘と決まりの箱から、内部の識別子を消す"
```

---

### Task 9: `CourseDirectory` — 学生に見せる科目の名簿

**Files:**
- Create: `app/services/course_directory.rb`
- Test: `test/services/course_directory_test.rb`

**Interfaces:**
- Produces:
  - `CourseDirectory.new(document)`
  - `#in_category(key) -> [Entry]`（番号順）
  - `#category_for(number) -> String | nil`
  - `#find(course_id) -> Entry | nil`
  - `#categories -> [String]`（科目が1件以上ある区分のキー）
  - `Entry = Struct.new(:course_id, :number, :name, :credits, :category, :required, :roles, :requires_approval, :selectable)`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '便覧に登録された科目は、登録の区分・必修・役割・承認・選べるかを持つ'
test '登録された科目の名前と単位は、Course の行があればそちらを使う'
test '登録が無い Course は、番号パターンで区分が決まれば名簿に出る'
test 'パターンで出た科目は、必修でも役割持ちでも承認要でもなく、選べる'
test '番号パターンで区分が決まらない Course は、名簿に出ない'
test '科目番号の無い Course は、名簿に出ない'
test '学生の自由入力で作られた Course(custom_category あり)は、名簿に出ない'
test '同じ番号で名前の違う Course が2行あれば、2件とも出る'
test 'categories が空の文書では、どの区分も空を返す'           # 例外にしない
test 'in_category は番号順に返す'
test 'find は Course の id から1件を返す'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/services/course_directory_test.rb`
Expected: FAIL

- [ ] **Step 3: `CourseDirectory` を実装する**

`Course.where.not(course_number: [nil, '']).where(custom_category: nil)` を1回だけ引き、番号で索引する。区分の決め方は仕様 §1 の1〜3。
パターンの照合は Task 1 の `CurriculumImport::NumberPatterns` を使う。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bin/rails test test/services/course_directory_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 学生に見せる科目の名簿を courses テーブルから作る"
```

---

### Task 10: デモの `Course` を、便覧から切り離す

**Files:**
- Create: `db/course_master.json`、`lib/tasks/course_master.rake`
- Modify: `app/services/demo_data.rb`（`#import_courses`、45〜52行）
- Test: `test/services/demo_data_test.rb`

**Interfaces:**
- Consumes: なし
- Produces: `db/course_master.json` は `[{ "number": "知能101", "name": "…", "credits": 1 }, …]`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'デモの投入で、course_master.json の科目が Course になる'
test '同じ番号・名前の行は1件にまとまる'
test 'デモ学生の履修48件が、すべて Course に当たる'
test '便覧の courses を空にしても、デモの投入が通る'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/services/demo_data_test.rb`
Expected: FAIL

- [ ] **Step 3: 種ファイルを作る**

`lib/tasks/course_master.rake` に `course_master:build`。`config/curricula/**/*.json` の `courses` から `number` を持つ行を集め、`(番号, 名前)` で1件にまとめ、`number` 順に並べて `db/course_master.json` に書く。単位は最初に出た値を採る（`DemoData#import_courses` の先着優先と同じ理由）。
タスクを1回流し、結果をコミットする。

- [ ] **Step 4: `DemoData` を種ファイルに向ける**

`import_courses` の引数を無くし、`db/course_master.json` を読む。戻り値の形（`{ 科目番号 => Course }`）は変えない。`import_enrollments` はそのまま。

- [ ] **Step 5: テストが通ることを確かめる**

Run: `bin/rails test test/services/demo_data_test.rb && bin/rails db:seed`
Expected: PASS、seed が通る

- [ ] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: デモの科目を、便覧ではなく科目マスタの種ファイルから作る"
```

---

### Task 11: 学生の画面を、名簿に向ける

**Files:**
- Modify: `app/controllers/plans_controller.rb:33-45`、`app/views/plans/_add_course_box.html.erb`、`app/views/plans/show.html.erb:216-232`、`app/controllers/plan_courses_controller.rb:47-70`、`app/helpers/requirements_helper.rb:25-34`、`app/views/requirements/_courses.html.erb:7-12`
- Test: `test/controllers/plans_controller_test.rb`、`test/controllers/plan_courses_controller_test.rb`、`test/helpers/requirements_helper_test.rb`

**Interfaces:**
- Consumes: Task 9 の `CourseDirectory`
- Produces: 「便覧から選択」のフォームは `course_id`（`Course#id`）を送る

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# plans_controller_test.rb
test '便覧から選択に、番号パターンで区分が決まる科目が並ぶ'      # 便覧に登録が無くても出る
test '修得済み・予定済みの科目は、便覧から選択に出ない'
test '検索の一覧は200件で打ち切り、絞り込みを促す'
test '自由入力で作られた科目は、便覧から選択に出ない'

# plan_courses_controller_test.rb
test 'course_id で予定に追加できる'
test '名簿に無い course_id は追加できない'
test '選べない科目の course_id は追加できない'
test '同じ番号で名前の違う Course が2行あっても、送った id の行が予定に入る'

# requirements_helper_test.rb
test '学生の科目表が、名簿の区分ごとにまとまる'
test '科目が1件もない区分は出さない'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/controllers/plans_controller_test.rb test/controllers/plan_courses_controller_test.rb`
Expected: FAIL

- [ ] **Step 3: 読み手を名簿に替える**

`plans_controller#load_catalogue` は `CourseDirectory` を1つ作ってリクエストの中で使い回す（`@directory`）。`@persisted_numbers` は不要になるので消す。`@catalogue` は 200件で打ち切り、打ち切ったことを画面に出す。
`_add_course_box.html.erb` は `@directory.in_category` から、`@unavailable_numbers` に無いものを並べ、`value` を `Entry#course_id` にする。
`plan_courses_controller#find_catalogue_course` は `params[:course_id]` を受け、`@directory.find(id)` が返す `Entry` の `selectable` だけ確かめる。`AmbiguousCourse` の経路と、便覧の名前で `Course` を引く照合を外す。
`requirements_helper#courses_by_category` は名簿から作る。

**`student_workspace.rb:33` の `@courses_by_number` と `#catalogue_entries` は変えない。** 判定へ渡す key の振り替えは `Catalogue` の責任のままにする（Global Constraints「判定の数式を変えない」）。名簿は学生に見せるためだけのもの。

- [ ] **Step 4: 学生の科目表の説明文を直す**

`_courses.html.erb:9-12` の「この便覧に載っている科目です」を「あなたのコースで履修できる科目です。科目番号のパターンで数える科目を含みます」に替える。

- [ ] **Step 5: テストが通ることを確かめる**

Run: `bin/rails test test/controllers/ test/helpers/`
Expected: PASS

- [ ] **Step 6: 全体のテストとコミット**

```bash
bin/rails test && git add -A && git commit -m "feat: 学生の科目の選択と科目表を、科目名簿から描く"
```

---

### Task 12: 手順①を、1ページずつ見る形にする

**Files:**
- Create: `app/javascript/controllers/page_wizard_controller.js`
- Modify: `app/views/curricula/_pages.html.erb`、`app/views/curricula/_page_row.html.erb`
- Test: `test/controllers/curricula_controller_test.rb`、`test/system/curriculum_page_wizard_test.rb`（新規）

**Interfaces:**
- Produces: 一覧の送信は `pages[<番号>]=<種別>` のまま（サーバー側の `update` は変えない）

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# curricula_controller_test.rb（JavaScript 無しで成り立つこと）
test '1ページ目の画像が大きく出る'
test '3択のラジオが、すべてのページぶん HTML に入っている'    # JS が無くても一覧として使える
test 'ページ画像が無い下書きでは、取り出した文字の冒頭を代わりに出す'
test 'ページが1件も無い下書きでは、ページ数を指定する欄を出す'  # いまの挙動を保つ

# curriculum_page_wizard_test.rb（system）
test '種別を選ぶと次のページへ進む'
test '前へ・次へでページを行き来できる'
test '最後のページの次で、一覧が出る'
test '一覧の「直す」で、そのページの1枚表示に戻る'
test '一覧に、要件表・科目表・読まないの件数が出る'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/controllers/curricula_controller_test.rb`
Expected: FAIL

- [ ] **Step 3: `page_wizard_controller.js` を書く**

サーバーは全ページぶんの行を今までどおり HTML に出す。Stimulus が、1枚表示のときは当該ページ以外を隠し、一覧のときは全部出す。種別の選択はラジオの値を書き換えるだけで、送信はしない。
targets: `page`（各ページの要素）、`counter`、`summary`、`list`。actions: `next`・`prev`・`choose`・`showList`・`edit`。
キーボード: `←`・`→` で前後、`1`・`2`・`3` で 読まない・要件表・科目表。

- [ ] **Step 4: ビューを作り直す**

`_pages.html.erb` は、1枚表示の枠（画像・3択・前へ/次へ・進み具合）と、一覧の枠（サムネイル付きの行・件数・読み取りのボタン）を両方描き、Stimulus がどちらを見せるか決める。
`_page_row.html.erb` は、1枚表示用の大きい画像（横600px）と、一覧用のサムネイル（横64px）の両方を持つ。画像が無いページは `page['text']` の冒頭200字を出す。
`<noscript>` で、JavaScript が動かないときは一覧だけを出す（いまの画面と同じ形）。

- [ ] **Step 5: テストが通ることを確かめる**

Run: `bin/rails test test/controllers/curricula_controller_test.rb && bin/rails test:system TEST=test/system/curriculum_page_wizard_test.rb`
Expected: PASS

- [ ] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: 読むページの指定を、1ページずつ見て選ぶ形にする"
```

---

### Task 13: 確認したらそのまま読み取り、進み具合を見せる

**Files:**
- Modify: `app/javascript/controllers/read_pages_controller.js`、`app/controllers/curricula_controller.rb`（`#update`）、`app/views/curricula/_pages.html.erb`
- Create: `app/views/curricula/update.turbo_stream.erb`
- Test: `test/controllers/curricula_controller_test.rb`、`test/system/curriculum_page_wizard_test.rb`

**Interfaces:**
- Consumes: Task 12 の `page_wizard` が持つ一覧の画面
- Produces: `PATCH /curricula/:id` が Turbo Stream に応答し、警告を `data-save-warnings` に載せた要素を返す

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# curricula_controller_test.rb
test 'Turbo Stream で指定を保存でき、ページの節が差し替わる'
test '種別を替えて結果を外したとき、警告が応答に入る'
test '人が直した規則があるページを読み直すとき、警告が応答に入る'
test '警告が無いときは、警告の欄が空で返る'
test 'HTML の送信は、いまどおり画面を開き直す'            # JS 無しの経路を壊さない

# curriculum_page_wizard_test.rb（system）
test '「この指定で読み取る」で、保存から読み取りまで1回の操作で進む'
test '警告があるときは、確認してから読み取りに入る'
test '読み取り中に、進み具合のバーと n / m ページが出る'
test '読み取り中は、②③④の節を触れない'
test '読み取りが終わると、②へ進むボタンが出る'
test '1ページ失敗しても、残りのページを読み続ける'        # いまの挙動を保つ
test '読まないページしか無いときは、読み取りに入らず理由を出す'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/controllers/curricula_controller_test.rb`
Expected: FAIL

- [ ] **Step 3: `update` を Turbo Stream に応答させる**

`respond_to` を足す。`turbo_stream` は、ページの節を描き直し、`saved_notice` が作る文と各ページの `RereadWarning` を `data-save-warnings`（JSON の配列）に載せた要素を返す。`html` の経路（`redirect_to`）は変えない。

- [ ] **Step 4: 読み取りの流れをつなぐ**

`read_pages_controller.js` に `saveAndRead()` を足す。一覧の「この指定で読み取る」が呼ぶ。
1. フォームの `pages[...]` を `fetch` で `PATCH` する。失敗したら理由を一覧の上に出して止める。
2. 応答の Turbo Stream を適用し、`data-save-warnings` を読む。空でなければ `window.confirm` で見せ、断られたら止める。
3. そのまま `readAll()` に入る。

- [ ] **Step 5: 進み具合を見せる**

`readRows` が、進捗バー（`<progress>`）・`n / m ページ`・いま読んでいるページの経過秒数（1秒ごとに更新）を出す。
読み取りの間、`#requirements_review`・`#course-review`・`#publish` に `inert` と薄い見た目を当て、「読み取りが終わると出ます」を添える。終わったら外し、「要件表の確認へ」のボタンを出す（押すと `location.reload()` して `#requirements_review` へ飛ぶ）。

- [ ] **Step 6: テストが通ることを確かめる**

Run: `bin/rails test test/controllers/curricula_controller_test.rb && bin/rails test:system TEST=test/system/curriculum_page_wizard_test.rb`
Expected: PASS

- [ ] **Step 7: 全体のテストとコミット**

```bash
bin/ci && git add -A && git commit -m "feat: 指定の確認からそのまま読み取り、進み具合を見せる"
```

---

### Task 14: 取り込みの入口に、科目マスタの前提を1行書く

**Files:**
- Modify: `app/views/requirements/_upload.html.erb`、`README.md`
- Test: `test/controllers/requirements_controller_test.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '取り込みのフォームに、時間割を先に取り込む案内が出る'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bin/rails test test/controllers/requirements_controller_test.rb`
Expected: FAIL

- [ ] **Step 3: 文を足す**

取り込みフォーム: 「先にその年度の時間割PDFを取り込んでおくと、学生が科目を選べるようになります。便覧には、科目番号から区分が決まらない科目だけを登録します。」
README の該当箇所にも同じ順番を書く。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bin/rails test test/controllers/requirements_controller_test.rb`
Expected: PASS

- [ ] **Step 5: 全体のテストとコミット**

```bash
bin/ci && git add -A && git commit -m "docs: 便覧の取り込みの前に時間割を取り込む順番を書く"
```
