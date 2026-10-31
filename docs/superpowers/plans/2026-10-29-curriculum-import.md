# 便覧PDFの取り込み 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 便覧PDFを「卒業要件の確認」画面から取り込み、AIが埋めた下書きを人が確認して公開すると、そのPDFと同じ要件で判定が動くようにする。

**Architecture:** 判定ロジックを7つの型に閉じた規則データにし、科目表・規則・画面の章立てをすべて便覧のJSONへ移す。便覧はDBの `curricula` 行（下書きも公開済みも同じ行）。読み取りはGeminiの無料枠を1ページ1リクエストで呼び、科目番号から計算できるもの（提供元・言語・共通教育の区分）はAIに聞かず突き合わせに使う。

**Tech Stack:** Ruby 3.4 / Rails 8.1, PostgreSQL 17 (jsonb), Minitest, Hotwire (Turbo + Stimulus), Tailwind, Ghostscript (`gs`), `net/http`

**Spec:** `docs/superpowers/specs/2026-10-29-curriculum-import-design.md`

## Global Constraints

- 読み取れない・解釈できないものは、充足にせず必ず要確認（`:needs_review`）にする。「卒業できます」を誤って出さないことが最優先。
- 新しいgemを足さない。HTTPは標準の `net/http`。ジョブ基盤（Solid Queue / ActiveJob）を導入しない。
- 学生の履修・成績データを外部APIに送らない。送るのは便覧のページ画像とテキストだけ。
- `GraduationAssessment` のチェックIDは、2024年度の変換後JSONで現行の文字列をそのまま維持する（24個。画面が id で引いている）。
- 区分の語彙・必要単位・章立て・和名・卒業総単位を、Rubyの定数に書かない。すべて便覧のJSONから読む。
- コミット前に `bin/ci`（テスト + RuboCop + Brakeman + bundler-audit）を通す。pre-commitフックが同じものを実行する。
- コミットメッセージは Conventional Commits の prefix + 日本語本文。

## Review Focus

- **同じ科目番号の `Course` が2行あるとき。** 時間割取り込みが `(course_number, name)` で行を作るので、全角・半角や表記ゆれで重複しうる。便覧の1行に2つの `Course` が当たっても、どちらかを黙って選ばず要確認にする。→ Task 10
- **AIが同じ科目番号を2回返すとき。** ページをまたいで同じ科目が載っている便覧がある。後勝ちで上書きせず、重複として人に見せる。→ Task 17
- **`display` の行がどの区分も指していない／ある区分がどの行にも出ないとき。** 後者はその区分の科目が学生の画面から消える。公開を止める。→ Task 17
- **APIが200を返すのに本文がJSONでない、またはスキーマに合わないとき。** 例外で取り込み全体を落とさず、そのページだけ「未読取」にする。→ Task 15, 16
- **学生が指している便覧を消そうとしたとき。** 公開済みで学生が付いている便覧は消せない。→ Task 20

---

# 第1部 — 判定と画面をデータにする

この部が終わった時点で、2024年度の判定結果と画面は1文字も変わらない。取り込みはまだない。

---

### Task 1: 2024年度のいまの判定結果をフィクスチャに記録する

作り替える前に正解を作る。古いコードを消したあとでは作れない。

**Files:**
- Create: `lib/graduation_golden.rb`
- Create: `lib/tasks/graduation_golden.rake`
- Create: `test/services/graduation_assessment_golden_test.rb`
- Create: `test/fixtures/files/graduation_golden_2024.json`

**Interfaces:**
- Produces: `rake graduation:golden` が `test/fixtures/files/graduation_golden_2024.json` を書き出す。形は `{ "<ケース名>": { "actual": <snapshot>, "projected": <snapshot> } }`、snapshot は `{"status":, "counted_credits":, "review_notes": [], "checks": [{"id":,"status":,"counted_credits":,"required_credits":,"missing_courses":[]}]}`。`counted_credits` は `to_s('F')` の文字列。

- [ ] **Step 1: ケースを定義する rake タスクを書く**

ケースの組み立ては `lib/graduation_golden.rb` に `GraduationGolden.cases(curriculum)` として置き、
`lib/tasks/graduation_golden.rake` の `graduation:golden` から呼ぶ（Step 3 のテストからも呼ぶ）。実物の `config/curricula/intelligent_informatics/2024.json` を読み、`GraduationAssessment.new(curriculum:).call(completed:, registered:, planned:, unresolved:)` を下の6ケースで呼び、上の形で書き出す。

ケース名と内容:
- `empty` — すべて空
- `demo` — `db/demo_enrollments.json` の48件を completed/registered に振り分けたもの
- `all_completed` — `selectable` が true の全科目を completed（単位は科目表の `credits`）
- `missing_one_required` — `all_completed` から `required` の科目を1つ（キー順で最初）除く
- `clean_single_path` — `all_completed` から、単位が空の科目・`calculus_paths` の2本目の系列・
  `physics_roles` の2つ目を除いたもの（微積と物理をそれぞれ1系列だけ選んだ状態）
- `natural_cap_only` — `natural` 区分の先頭3科目だけ。他は空（自然系の上限2単位を切り分ける）

6ケースはどれも互いに違う結果になること。`all_completed` は全selectableを含むので、
そこに何かを足すだけのケースは `all_completed` と同値になり、網にならない。

- [ ] **Step 2: 実行して書き出す**

Run: `docker compose exec web bin/rails graduation:golden`
Expected: `test/fixtures/files/graduation_golden_2024.json` ができ、`demo` の `actual.status` が現在の判定と一致する（目視1回）。

- [ ] **Step 3: フィクスチャと突き合わせるテストを書く**

`test/services/graduation_assessment_golden_test.rb` に、同じ6ケースを組み立ててフィクスチャと `assert_equal` する1テスト。ケースの組み立ては Step 1 の `GraduationGolden.cases` を呼ぶ。

- [ ] **Step 4: テストが通ることを確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment_golden_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/graduation_golden.rb lib/tasks/graduation_golden.rake test/services/graduation_assessment_golden_test.rb test/fixtures/files/graduation_golden_2024.json
git commit -m "test: 2024年度の判定結果をフィクスチャに固定する"
```

---

### Task 2: 科目番号を分解する

**Files:**
- Create: `app/services/course_number.rb`
- Test: `test/services/course_number_test.rb`

**Interfaces:**
- Produces: `CourseNumber.prefix(number) => String | nil`、`CourseNumber.hundreds(number) => String | nil`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'prefix は数字の手前までを返す' do
  assert_equal '知能', CourseNumber.prefix('知能103')
  assert_equal '工共', CourseNumber.prefix('工共100')
  assert_equal 'C', CourseNumber.prefix('C101')
end

test 'hundreds は接頭辞と百の位を返す' do
  assert_equal '外2', CourseNumber.hundreds('外203')
  assert_equal '知能9', CourseNumber.hundreds('知能993')
end

test '全角数字も半角として読む' do
  assert_equal '知能', CourseNumber.prefix('知能１０３')
  assert_equal '知能1', CourseNumber.hundreds('知能１０３')
end

test '読めない値は nil' do
  [nil, '', '   ', '知能', '103'].each do |value|
    assert_nil CourseNumber.prefix(value), value.inspect
    assert_nil CourseNumber.hundreds(value), value.inspect
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/course_number_test.rb`
Expected: FAIL（`uninitialized constant CourseNumber`）

- [ ] **Step 3: `CourseNumber.prefix` と `CourseNumber.hundreds` を実装する**

`app/services/course_number.rb`。全角数字を半角に直してから「末尾の数字列」と「その手前」に分ける。どちらか一方でも空なら nil。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/services/course_number_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add app/services/course_number.rb test/services/course_number_test.rb
git commit -m "feat: 科目番号を接頭辞と百の位に分ける"
```

---

### Task 3: 規則の型 — credit_sum / all_required / one_of_paths

**Files:**
- Create: `app/services/graduation_assessment/rules.rb`
- Create: `app/services/graduation_assessment/rules/base.rb`
- Create: `app/services/graduation_assessment/rules/credit_sum.rb`
- Create: `app/services/graduation_assessment/rules/all_required.rb`
- Create: `app/services/graduation_assessment/rules/one_of_paths.rb`
- Test: `test/services/graduation_assessment/rules_test.rb`

**Interfaces:**
- Consumes: `Catalogue`（Task 6 で差し替わるが、`courses` / `mandatory` / `roles` / `find` は不変）、`Ledger`
- Produces:
  - `GraduationAssessment::Rules::Outcome = Struct.new(:satisfied, :review, :counted, :missing, keyword_init: true)`（`counted` は `BigDecimal`、`missing` は科目名の配列）
  - `Rules::Base#initialize(definition)` / `#id` / `#label` / `#evaluate(catalogue, ledger) => Outcome` / `#check(catalogue, ledger) => Check`
  - `Rules::Base#reconcile(catalogue, ledger)` — 既定は何もしない
  - `Rules.status(satisfied, review) => :satisfied | :needs_review | :unmet`（`CreditCheck.status` をここへ移す。`Evaluation#status` もこれを使う）
  - `Rules.condition(definition) => Rules::Base`（未知の `type` は `Rules::Unknown`、Task 4）

定義の欄:
- `credit_sum`: `id` `label` `categories` `required_credits` `detail` `source_page`
- `all_required`: `id` `label` `expected_course_count` `required_credits` `detail` `source_page`
- `one_of_paths`: `id` `label` `paths`（役割キーの配列の配列） `review_note` `detail` `source_page`
  — `review_note` は、複数の経路が混ざっていたときに要確認として出す文面。便覧ごとに違うので
  データから取る（2024年度は微分積分と物理で文言が別）

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'credit_sum は指定区分の算入単位を合計する' do
  # health 2単位を算入した ledger
  outcome = rule('type' => 'credit_sum', 'id' => 'health', 'label' => '健康運動系',
                 'categories' => ['health'], 'required_credits' => 2).evaluate(@catalogue, @ledger)
  assert outcome.satisfied
  assert_equal BigDecimal('2'), outcome.counted
end

test 'credit_sum は参照する区分に未確定があれば review' do
  @ledger.mark_uncertain('category' => 'health')
  refute_predicate rule_health.evaluate(@catalogue, @ledger).satisfied
  assert rule_health.evaluate(@catalogue, @ledger).review
end

test 'all_required は未修得の必修名を missing に入れる' do
  outcome = rule('type' => 'all_required', 'id' => 'required_all', 'label' => '必修',
                 'expected_course_count' => 2, 'required_credits' => 4).evaluate(@catalogue, @ledger)
  assert_equal ['必修B'], outcome.missing
end

test 'all_required は科目表の必修数が expected_course_count と違えば review' do
  outcome = rule('type' => 'all_required', 'id' => 'required_all', 'label' => '必修',
                 'expected_course_count' => 99, 'required_credits' => 4).evaluate(@catalogue, @ledger)
  assert outcome.review
end

test 'all_required は科目表の必修単位合計が required_credits と違えば review' do
  outcome = rule('type' => 'all_required', 'id' => 'required_all', 'label' => '必修',
                 'expected_course_count' => 2, 'required_credits' => 99).evaluate(@catalogue, @ledger)
  assert outcome.review
end

test 'one_of_paths は1つの経路を丸ごと満たせば充足' do
  # st_1 と st_2 を算入した ledger
  outcome = rule('type' => 'one_of_paths', 'id' => 'calculus', 'label' => '微分積分',
                 'paths' => [%w[st_1 st_2], %w[intro_1 intro_2]]).evaluate(@catalogue, @ledger)
  assert outcome.satisfied
end

test 'one_of_paths は経路の一部だけでは充足しない' do
  # st_1 だけ
  refute_predicate(..., :satisfied)
end

test 'one_of_paths#reconcile は2つの経路が混ざっていたら全部を要確認にする' do
  # st_1,st_2,intro_1,intro_2 すべて算入
  subject.reconcile(@catalogue, @ledger)
  assert_equal BigDecimal('0'), @ledger.items['st_1'].counted
  assert @ledger.notes.any? { |note| note.include?('系列') }
end

test 'check は id・label・required_credits・source を持つ Check を返す' do
  check = rule_health.check(@catalogue, @ledger)
  assert_equal 'health', check.id
  assert_equal :satisfied, check.status
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment/rules_test.rb`
Expected: FAIL

- [ ] **Step 3: `Rules::Base` と3つの型を実装する**

`Base#check` は `evaluate` の `Outcome` から `Check` を組む。`CreditCheck.status` の中身を `Rules.status` に移し（`CreditCheck.status` はそれを呼ぶだけにする）、`detail` の文面は既存の `CreditCheck#detail` と同じ組み立て（「<説明> 確認済み算入X／必要Y単位。」＋不足・未確認の付け足し）を `Base#detail` に移す。`source` は `definition['source_page']` から作る。T7 で `credit_check.rb` を消すので、ロジックはここに残す。

`one_of_paths#reconcile` は、2つ以上の経路に算入済みの役割があるとき `Ledger#quarantine_roles` で全役割を要確認にする（現在の `BasicAlternatives` と同じ）。理由の文面は定義の `review_note` をそのまま使う。欄がなければ `"#{label}の選択が重複しており、確認が必要"` に落とすが、要確認にすること自体は必ず行う。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment/rules_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add app/services/graduation_assessment/rules.rb app/services/graduation_assessment/rules test/services/graduation_assessment/rules_test.rb
git commit -m "feat: 規則の型に credit_sum・all_required・one_of_paths を足す"
```

---

### Task 4: 規則の型 — grouped_max / any_of / all_of / Unknown

**Files:**
- Create: `app/services/graduation_assessment/rules/grouped_max.rb`
- Create: `app/services/graduation_assessment/rules/any_of.rb`
- Create: `app/services/graduation_assessment/rules/all_of.rb`
- Create: `app/services/graduation_assessment/rules/unknown.rb`
- Modify: `app/services/graduation_assessment/rules.rb`
- Modify: `app/services/graduation_assessment/ledger.rb`
- Test: `test/services/graduation_assessment/rules_composite_test.rb`

**Interfaces:**
- Consumes: `CourseNumber`（Task 2）、`Rules::Base`（Task 3）
- Produces: `Rules.condition` が `grouped_max` / `any_of` / `all_of` を返す。未知の `type` は `Rules::Unknown`。

定義の欄:
- `grouped_max`: `id` `label` `category` `group_by`（`"number_prefix"` / `"number_prefix_hundreds"` / `"field:<科目の欄名>"`） `required_credits`
  — 工学融合は `"number_prefix"`、外国語は `"field:language"`。**番号から言語は出ない**
  （外7xx にインドネシア語・タイ語・ラテン語・ロシア語が同居している）
- `any_of`: `id` `label` `options`（`credit_sum` / `grouped_max` / `all_of` の定義の配列）
- `all_of`: `conditions`（`credit_sum` / `grouped_max` の定義の配列）。`any_of` の中だけに現れる

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'grouped_max は最大のグループの単位を数える' do
  # fusion に 機械991(2) 機械992(2) 社基991(2)
  outcome = grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger)
  assert_equal BigDecimal('4'), outcome.counted
  assert outcome.satisfied
end

test 'grouped_max はグループを合算しない' do
  # fusion に 機械991(2) 社基991(2) だけ → 最大は2
  refute_predicate grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger), :satisfied
end

test 'grouped_max は field:language で外国語を言語ごとに分ける' do
  # 外201(2) 外202(2) 外301(2) → 最大は外2の4単位
  assert_equal BigDecimal('4'), grouped_max('field:language', 4).evaluate(@catalogue, @ledger).counted
end

test 'grouped_max は field: の欄が空の科目が算入されていたら review' do
  assert grouped_max('field:language', 4).evaluate(@catalogue, @ledger).review
end

test 'grouped_max は科目番号が読めない科目が算入されていたら review' do
  # number が nil の科目を fusion に算入
  assert grouped_max('number_prefix', 4).evaluate(@catalogue, @ledger).review
end

test 'any_of はどれか1つ満たせば充足' do
  # 英語8 + ドイツ語4 → 2つ目の all_of が通る
  assert_predicate foreign_language_rule.evaluate(@catalogue, @ledger), :satisfied
end

test 'any_of はどれも満たさなければ不足' do
  refute_predicate foreign_language_rule.evaluate(@catalogue, @ledger), :satisfied
end

test 'any_of はどれかの選択肢が review なら review' do
  assert foreign_language_rule.evaluate(@catalogue, @ledger).review
end

test '未知の型は充足にならず review になる' do
  outcome = Rules.condition('type' => 'gpa', 'id' => 'gpa', 'label' => 'GPA')
                 .evaluate(@catalogue, @ledger)
  refute outcome.satisfied
  assert outcome.review
end

test '未知の型は理由を ledger の notes に残す' do
  Rules.condition('type' => 'gpa', 'id' => 'gpa', 'label' => 'GPA').evaluate(@catalogue, @ledger)
  assert @ledger.notes.any? { |note| note.include?('gpa') }
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment/rules_composite_test.rb`
Expected: FAIL

- [ ] **Step 3: 4つの型を実装する**

`grouped_max` は `Ledger` に集計用のメソッドを足す。`number_prefix` / `number_prefix_hundreds` は `CourseNumber` で、`field:<欄名>` はその欄の値でグループ分けする。算入済みの科目でグループが決まらないもの（番号が読めない、欄が空）があれば `review` を立てる。既存の `grouped_credits(category, field)` は旧 `fusion_check` がまだ使うので触らない。

`any_of#evaluate` は `options` を順に `evaluate` し、1つでも `satisfied` なら充足。`counted` は最初の選択肢のもの。どれかが `review` なら `review`。`all_of` は全部 `satisfied` で充足。入れ子は `any_of` → `all_of` の2段まで。それ以上は `Rules::Unknown` にする。

`Rules::Unknown#evaluate` は `Outcome(satisfied: false, review: true, counted: 0)` を返し、`ledger.notes << "#{id}：規則の型「#{type}」をこのアプリは解釈できません"` を足す。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment/rules_composite_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add app/services/graduation_assessment/rules app/services/graduation_assessment/ledger.rb test/services/graduation_assessment/rules_composite_test.rb
git commit -m "feat: 規則の型に grouped_max・any_of・未知の型を足す"
```

---

### Task 5: 規則の型 — cap / exclude

**Files:**
- Create: `app/services/graduation_assessment/rules/cap.rb`
- Create: `app/services/graduation_assessment/rules/exclude.rb`
- Modify: `app/services/graduation_assessment/rules.rb`
- Modify: `app/services/graduation_assessment/ledger.rb`
- Test: `test/services/graduation_assessment/rules_adjustment_test.rb`

**Interfaces:**
- Produces: `Rules.adjustment(definition) => Rules::Cap | Rules::Exclude`
  - `Rules::Cap#apply(catalogue, ledger)`
  - `Rules::Exclude#reason_for(course) => String | nil`

定義の欄:
- `cap`: `id` `category` `credits`
- `exclude`: `id` `category` `number_prefix`（任意） `reason`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'cap は区分の算入をキー順に打ち切る' do
  # natural に 2単位の科目3つ、cap は 2
  cap.apply(@catalogue, @ledger)
  assert_equal BigDecimal('2'), @ledger.sum(['natural'])
end

test 'cap は打ち切った科目に理由を残す' do
  cap.apply(@catalogue, @ledger)
  assert @ledger.items.values.any? { |item| item.reason.include?('上限') }
end

test 'exclude は区分だけの指定で理由を返す' do
  rule = Rules.adjustment('type' => 'exclude', 'category' => 'excluded',
                          'reason' => '卒業単位への算入対象外')
  assert_equal '卒業単位への算入対象外', rule.reason_for('category' => 'excluded', 'number' => '情101')
  assert_nil rule.reason_for('category' => 'fusion', 'number' => '機械991')
end

test 'exclude は number_prefix があれば接頭辞も一致したときだけ返す' do
  rule = Rules.adjustment('type' => 'exclude', 'category' => 'fusion',
                          'number_prefix' => '知能', 'reason' => '自コース提供')
  assert_equal '自コース提供', rule.reason_for('category' => 'fusion', 'number' => '知能993')
  assert_nil rule.reason_for('category' => 'fusion', 'number' => '機械991')
end

test 'exclude は科目番号が読めない科目には当たらない' do
  rule = Rules.adjustment('type' => 'exclude', 'category' => 'fusion',
                          'number_prefix' => '知能', 'reason' => '自コース提供')
  assert_nil rule.reason_for('category' => 'fusion', 'number' => nil)
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment/rules_adjustment_test.rb`
Expected: FAIL

- [ ] **Step 3: `Rules::Cap` と `Rules::Exclude` を実装する**

`Cap#apply` は現在の `Ledger#apply_natural_cap` と同じ（キー順に配分、打ち切った科目の `reason` を「<区分名>は卒業算入上限N単位（この科目はM単位を算入）」に）。`Ledger#apply_natural_cap` は**この時点では消さない**。`Evaluation#call` がまだ呼んでおり、消すと Task 7 まで判定が壊れる。Task 7 で `Evaluation` を書き換えるときに一緒に消す。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment/rules_adjustment_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add app/services/graduation_assessment/rules app/services/graduation_assessment/ledger.rb test/services/graduation_assessment/rules_adjustment_test.rb
git commit -m "feat: 規則の型に cap・exclude を足す"
```

---

### Task 6: Catalogue を便覧データから作る

> **このタスクは足すだけ。何も消さず、動いているものを1つも変えない。**
> 旧定数 `COMMON` / `REQUIRED` / `INNER` / `ELECTIVE` / `CATEGORIES` / `PROVIDERS` /
> `SOURCE` / `REQUIRED_SOURCE` は、`CommonChecks`・`SpecialistChecks`・`Evaluation`・
> `CreditCheck`・`RoleCheck`・`EntryNormalizer`・`PlanCoursesController` がまだ使っている。
> 消すのは Task 7。`requirements` と `exclusion` の中身も Task 7 まで現状のまま。
>
> **この時点の便覧はまだ旧形式**（`categories` も `rules` も `display` も無い）。
> 新しいメソッドはその状態で呼ばれても例外にならず、空を返すこと。`fetch` は使わない。

**Files:**
- Modify: `app/services/graduation_assessment/catalogue.rb`
- Test: `test/services/graduation_assessment/catalogue_test.rb`

**Interfaces:**
- Consumes: `Rules`（Task 3〜5）
- Produces（すべて追加）: `Catalogue#categories` / `#category_keys` / `#counted_category_keys` /
  `#conditions` / `#adjustments` / `#display` / `#course_for(number)`。
  `#label_for(key)` は Task 5 で追加済み。
- 残すもの: 旧定数すべて、`requirements`、`exclusion` の現在の実装、`ZERO`。
- 旧形式のドキュメントでは `categories` / `conditions` / `adjustments` は空配列、
  `display` は空ハッシュを返す。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'category_keys は便覧の categories から来る' do
  assert_equal %w[foundation excluded], catalogue.category_keys
end

test '旧形式の便覧でも例外にならず空を返す' do
  old = GraduationAssessment::Catalogue.new('courses' => [], 'requirements' => {})
  assert_empty old.categories
  assert_empty old.conditions
  assert_empty old.adjustments
  assert_empty old.display
end

test 'counted_category_keys は counts_toward_total が false の区分を除く' do
  assert_equal ['foundation'], catalogue.counted_category_keys
end

test 'conditions は rules の並び順どおりに返る' do
  assert_equal %w[common_total foreign_language], catalogue.conditions.map(&:id)
end

test 'adjustments は cap と exclude だけを返す' do
  assert_equal %w[natural_cap own_fusion], catalogue.adjustments.map(&:id)
end

test 'find_by_number は科目番号で科目を引く' do
  assert_equal '離散数学', catalogue.find_by_number('知能103')['name']
end

test 'exclusion は exclude 規則の理由を返す' do
  assert_equal '自コース提供', catalogue.exclusion('category' => 'fusion', 'number' => '知能993')
end

test '便覧にない区分の科目は EntryNormalizer が要確認にする' do
  # category: 'nonexistent' の科目
  assert @ledger.notes.any? { |note| note.include?('分類が未確認') }
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment/catalogue_test.rb`
Expected: FAIL

- [ ] **Step 3: `Catalogue` を書き換える**

`initialize(document)` で `categories` / `rules` / `display` を**あれば**読む。`rules` は `type` が
`cap` / `exclude` のものを `adjustments`、それ以外を `conditions` に振り分け、
`Rules.adjustment` / `Rules.condition` で作る。どれも無ければ空。

`required_roles` は、`rules` があるときは `conditions` のうち `one_of_paths` の `paths` を
平らにしたものから作り、無いときは今までどおり `requirements` から作る。
旧形式でも `specified?` が同じ答えを返すこと。

**`EntryNormalizer` と `PlanCoursesController` はこのタスクでは触らない。**
どちらも旧定数を使っており、切り替えは Task 7 で旧クラスを消すときに一緒に行う。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment/` と
`docker compose exec web bin/ci`
Expected: PASS。旧形式の便覧のまま、既存の判定が1つも変わっていないこと。

- [ ] **Step 5: コミット**

```bash
git add app/services/graduation_assessment test/services/graduation_assessment
git commit -m "refactor: Catalogue の定数を便覧データに移す"
```

---

### Task 7: Evaluation を規則の並びで回す

> **実行順: このタスクは Task 8 の後に行う。** 便覧に `rules` が入っていない状態で
> `Evaluation` を規則に切り替えると、条件ゼロで判定が走る。
>
> **ここが第1部の山場。** 旧コードを消して規則に切り替えた結果が、Task 1 で記録した
> ゴールデンマスターと一致するかどうかで、この改修全体の成否が決まる。

**Files:**
- Modify: `app/services/graduation_assessment/evaluation.rb`
- Delete: `app/services/graduation_assessment/common_checks.rb`
- Delete: `app/services/graduation_assessment/specialist_checks.rb`
- Delete: `app/services/graduation_assessment/basic_alternatives.rb`
- Delete: `app/services/graduation_assessment/credit_check.rb`
- Delete: `app/services/graduation_assessment/role_check.rb`
- Modify: `app/services/graduation_assessment/ledger.rb`（`apply_natural_cap` を消す）
- Modify: `app/services/graduation_assessment/catalogue.rb`（旧定数・`requirements`・`exclusion` の旧実装を消す）
- Modify: `app/services/graduation_assessment/entry_normalizer.rb`（`Catalogue::CATEGORIES.exclude?` を `@catalogue.category_keys.exclude?` に。`inspect_provider` / `inspect_language` を消す）
- Modify: `app/controllers/plan_courses_controller.rb`（`CUSTOM_CATEGORIES = Catalogue::CATEGORIES - ['excluded']` を、その便覧の `counted_category_keys` を要求時に読む形に）
- Modify: `config/curricula/intelligent_informatics/2024.json`（`requirements` と `courses[].provider` を消す）
- Delete: `lib/tasks/curriculum_convert.rake`（旧定数を読むので Task 7 以降は動かない。残すと例外を出す死コード）
- Modify: `config/curricula/README.md`（format_version 2 の構成に書き直す。いまは
  `sources` / `requirements` / `courses` の4行の表で「汎用のルールDSLではない」と書いてあるが、
  便覧は22区分・27規則・`display` を持つようになり、条件式は実際に規則のDSLになった。
  便覧を保守する人がこれを読んで規則の存在に気づけない）
- Modify: `test/services/graduation_assessment_test.rb`

**Interfaces:**
- Consumes: `Catalogue#conditions` / `#adjustments`（Task 6）、`Rules.status`（Task 3）
- Produces: `Evaluation#call(completed, future, unresolved) => Snapshot`（引数も戻りも変わらない）

Task 6 が意図的に見送ったテスト2件も、ここで書く（どちらも切り替え後でないと成立しない）:

```ruby
test 'exclusion は exclude 規則の理由を返す' do
  assert_equal '自コース提供', catalogue.exclusion('category' => 'fusion', 'number' => '知能993')
end

test '便覧にない区分の科目は EntryNormalizer が要確認にする' do
  # category: 'nonexistent' の科目
  assert @ledger.notes.any? { |note| note.include?('分類が未確認') }
end
```

- [ ] **Step 1: 既存テストを新形式に書き直す**

`test/services/graduation_assessment_test.rb` の `setup` が組み立てている旧形式のドキュメント（`requirements` ハッシュ、区分の決め打ち）を、`categories` / `rules` / `courses` の形に書き直す。**アサートしている id・status・単位は1つも変えない。** `detail` の文面を見ているアサートは、同じ文面を `rules[].detail` に入れて通す。

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment_test.rb`
Expected: FAIL

- [ ] **Step 3: `Evaluation#call` を書き換える**

```ruby
def call(completed, future, unresolved)
  EntryNormalizer.new(@catalogue, @ledger).call(completed, future, unresolved)
  @catalogue.conditions.each { |rule| rule.reconcile(@catalogue, @ledger) }
  @catalogue.adjustments.each { |rule| rule.apply(@catalogue, @ledger) if rule.respond_to?(:apply) }
  checks = @catalogue.conditions.map { |rule| rule.check(@catalogue, @ledger) }
  Snapshot.new(status: status(checks), counted_credits: @ledger.total, checks: checks.freeze,
               review_notes: @ledger.notes.uniq.freeze, course_results: @ledger.course_results)
end
```

`status` は判定のしかたを変えず、`CreditCheck.status` ではなく `Rules.status` を呼ぶ。削除する5ファイルの参照が残っていないことを `grep -rn` で確認する。

**このタスクで初めて、ゴールデンマスターが等価性を証明する。** Task 8 までは旧コードが答えを
出していたので通って当然だった。ここで赤くなったら規則の定義かコードが違っている。
**フィクスチャを書き換えて合わせてはいけない。**

**便覧を読み込んだ時点で検める（Task 6 のレビューで判明。どれも「壊れた便覧が正しく見える」）。**
format 2 のドキュメントに対して、`Catalogue#initialize` で次を検査し、外れていれば `ArgumentError`:

- `courses` の `number` に**重複**がある
  （`course_for` が黙って片方を返し、学生の履修が違う科目に解決される）
  — **空の `number` は弾かない。** 2024年度の「知能情報特別講義Ⅴ・Ⅵ」は分類表にしか
    載っていない科目で、意図的に `number: null` と `review_reason` を持つ。弾くと便覧が読めなくなる。
    番号の無い科目は `course_for` で引けないだけで、それが正しい（既に要確認になっている）
- `categories` の要素に `key` が無い、または `key` が重複している
  （`category_keys` に nil が混じり、和名の対応表も後勝ちで潰れる）
- `rules` が参照する区分が `categories` に無い

あわせて `required_roles` をこの時点で組み立てる。いまは遅延評価で、`one_of_paths` に `paths` が
無いと**学生の判定中に** `KeyError` になる。調整規則は load 時に落ちるのに条件規則だけ
判定中に落ちるのは筋が通らない。

旧コードと一緒に消すもの: `Ledger#apply_natural_cap`（Task 5 の `Cap` が置き換える）、
`EntryNormalizer#inspect_provider` / `#inspect_language`（Task 4 の `grouped_max` が置き換える）、
`Catalogue` の旧定数と `requirements`、便覧の `requirements` と `courses[].provider`。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A app/services/graduation_assessment test/services/graduation_assessment_test.rb
git commit -m "refactor: 判定を規則の並びの解釈に置き換える"
```

---

### Task 8: 2024年度の便覧を format 2 に変換する

> **実行順: このタスクは Task 7 より先に行う。** 旧コード（`Catalogue#initialize` の
> `document.fetch('requirements')`、`Catalogue#exclusion` の `course['provider']`、
> `Ledger` の `course['key']`）はまだ動いている。Task 7 が `Evaluation` を規則に切り替える前に
> 便覧へ規則を足しておかないと、`conditions` が空のまま判定が走って全部崩れる。
> 逆に、ここで旧コードが読む欄を消すと Task 7 までの判定が壊れる。
>
> **だからこの変換は「足すだけ」。** `requirements` も `courses[].key`（英語キー）も
> `courses[].provider` も**そのまま残す**。消すのは Task 7（旧クラスと `requirements`・`provider`）。
> **`key` は最後まで英語のまま**（Task 10 で結合が科目番号に移り、キーは便覧の中だけの識別子になる）。

**Files:**
- Create: `lib/tasks/curriculum_convert.rake`
- Modify: `config/curricula/intelligent_informatics/2024.json`
- Modify: `test/services/graduation_assessment_golden_test.rb`

**Interfaces:**
- Consumes: Task 1 の `test/fixtures/files/graduation_golden_2024.json`
- Produces: `format_version: 2` の `config/curricula/intelligent_informatics/2024.json`

- [ ] **Step 1: 変換の rake タスクを書く**

`curriculum:convert[path]`。旧形式を読み、

- `categories` — 旧 `Catalogue::CATEGORIES` の22区分を、`StudentWorkspaceHelper::CATEGORY_LABELS` の和名つきで並べる。`counts_toward_total` は `excluded` だけ false。
- `rules` — 現行コードの24個のチェックを、**IDと label と detail の文面をそのまま**規則にする。内訳は設計書 §1 の対応表のとおり。`natural_cap`（cap, natural, 2）と、`excluded` / `fusion`+`知能` の2つの `exclude` を足す。
- `display` — `StudentWorkspaceHelper::PLANNER_GROUPS` と `PlansHelper::PLANNER_SUBTOTALS` をそのまま写す。`total_credits` は 130。`credits_from_check` は `DashboardMetrics::CHECK_DRIVEN_ROWS` に入っている行だけ true。
- `courses` — **触らない。** `key`（英語キー）も `provider` も `review_reason` もそのまま。
  規則は科目を `number` と欄の値で見る（`grouped_max` は接頭辞か `language` 欄、`exclude` は `number_prefix`）ので、
  キーを変える必要がない。`language` 欄も残す。
  **2024年度のキーは最後まで英語のまま。** Task 10 で `courses.curriculum_key` を落とすと、
  キーは便覧の中だけの識別子になる（結合は科目番号が担う）ので、揃える理由がなくなる。
- `requirements` — **残す。** Task 7 が旧クラスを消すときに一緒に消す。
- 規則の文面で、既に判明している必須事項:
  - `one_of_paths` の `review_note` に、微分積分と物理それぞれの注記を一字一句入れる
    （「微分積分学の系列が混在・重複しており、組合せと重複算入の確認が必要」
    「物理学の代替科目を重複して修得・予定しており、重複算入の確認が必要」）
  - `all_required` の `detail` は「余剰単位による代用は不可。」だけ。前段の科目数の文はコードが組む
  - `cap` に `label` 欄は置かない。区分名は `categories[]` から引く

- [ ] **Step 2: 変換を実行する**

Run: `docker compose exec web bin/rails "curriculum:convert[config/curricula/intelligent_informatics/2024.json]"`
Expected: `format_version` が 2 になり、`rules` が24＋3件、`courses` が484件。

- [ ] **Step 3: ゴールデンマスターのテストを走らせる**

Run: `docker compose exec web bin/rails test test/services/graduation_assessment_golden_test.rb`
Expected: PASS。ただしこの時点では **まだ旧コードが判定している**ので、通って当然であり
等価性の証拠にはならない。ここで確かめているのは「足した欄が旧コードを壊していないこと」だけ。
規則が本当に同じ答えを出すかは Task 7 で判明する。

- [ ] **Step 4: 全テストを走らせる**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/tasks/curriculum_convert.rake config/curricula/intelligent_informatics/2024.json
git commit -m "feat: 2024年度の便覧を規則データ形式に変換する"
```

---

### Task 9: 便覧をDBに置く

**Files:**
- Create: `db/migrate/20261030000000_create_curricula.rb`
- Create: `app/models/curriculum.rb`
- Delete: `app/repositories/curriculum_repository.rb`
- Delete: `test/repositories/curriculum_repository_test.rb`
- Modify: `db/seeds.rb`, `app/services/demo_data.rb`
- Test: `test/models/curriculum_test.rb`

**Interfaces:**
- Produces:
  - `curricula`: `slug`（string, null: false） `admission_year`（integer, null: false） `faculty_name` `department_name` `title` `document`（jsonb, null: false, default: {}） `source_filename` `pages`（jsonb, default: []） `published_at`
  - 部分一意索引 `(slug, admission_year) where published_at is not null`
  - `Curriculum.published` / `#published?` / `#catalogue => GraduationAssessment::Catalogue`
  - `Curriculum.seed_from_file(path) => Curriculum`（`document` を入れ、`published_at` を立てる。slug はディレクトリ名、年度はファイル名）

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '公開済みは同じ slug と年度で2つ作れない' do
  Curriculum.create!(slug: 'x', admission_year: 2024, document: {}, published_at: Time.current)
  assert_raises(ActiveRecord::RecordNotUnique) do
    Curriculum.create!(slug: 'x', admission_year: 2024, document: {}, published_at: Time.current)
  end
end

test '下書きは同じ slug と年度で何件でも作れる' do
  2.times { Curriculum.create!(slug: 'x', admission_year: 2024, document: {}) }
  assert_equal 2, Curriculum.where(slug: 'x').count
end

test 'seed_from_file は便覧ファイルを公開済みとして入れる' do
  curriculum = Curriculum.seed_from_file(Rails.root.join('config/curricula/intelligent_informatics/2024.json'))
  assert_equal 'intelligent_informatics', curriculum.slug
  assert_equal 2024, curriculum.admission_year
  assert_predicate curriculum, :published?
  assert_equal 484, curriculum.document.fetch('courses').size
end

test 'catalogue は便覧の規則を返す' do
  assert_includes curriculum.catalogue.conditions.map(&:id), 'common_total'
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/models/curriculum_test.rb`
Expected: FAIL

- [ ] **Step 3: マイグレーションとモデルを書き、`CurriculumRepository` を消す**

`db/seeds.rb` は `Curriculum.seed_from_file` を `config/curricula/**/*.json` に対して呼ぶ。`DemoData.load!` は `Curriculum.published.find_by!(slug: DemoAccount::DEPARTMENT, admission_year: DemoAccount::ADMISSION_YEAR)` から読む。`grep -rn CurriculumRepository` が空になること。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails db:migrate && docker compose exec web bin/rails test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A db app/models/curriculum.rb app/services/demo_data.rb test/models/curriculum_test.rb
git commit -m "feat: 便覧をDBのcurriculaに置く"
```

---

### Task 10: 科目番号で便覧を引く

**Files:**
- Create: `db/migrate/20261030010000_replace_curriculum_key_with_number_lookup.rb`
- Modify: `app/models/course.rb`, `app/models/student_course.rb`, `app/models/student.rb`
- Modify: `app/controllers/concerns/student_workspace.rb`, `app/controllers/plan_courses_controller.rb`, `app/controllers/plans_controller.rb`
- Modify: `app/helpers/student_workspace_helper.rb`, `app/services/dashboard_metrics.rb`, `app/services/demo_data.rb`
- Modify: `db/demo_enrollments.json`
- Modify: `app/views/plans/_enrollment_card.html.erb`, `_plan_card.html.erb`, `show.html.erb`
- Test: `test/controllers/student_workspace_test.rb`, `test/services/demo_data_test.rb`

**Interfaces:**
- マイグレーション: `courses.curriculum_key` と索引を削除、`courses.custom_category`（string）を追加、`students.curriculum_id`（bigint, FK, null許可）を追加、`planned_courses.approval_confirmed`（boolean, null許可）を追加
- Produces:
  - `Student#curriculum`（belongs_to, optional）
  - `Course#custom?` = `custom_category.present?`
  - **`@curriculum` は便覧のドキュメント（Hash）のまま。** `Curriculum` レコードではない。
    コントローラとビューに `@curriculum.fetch(...)` の読み手が8か所あり、レコードに変えても
    得るものがない。`load_workspace` がレコードを引いて `@curriculum = record.document` を置く。
    レコード自体が要るのは、便覧を引く場所と公開まわりだけ
  - `@courses_by_number` が `@courses_by_key` に代わる（`document['courses']` を `number` で索引）
  - `StudentCourse#assessment_entry` の `key` は `course.course_number`
  - `StudentWorkspaceHelper#course_category(course, courses_by_number)` — 第1引数が `Course` に変わる

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '履修は科目番号で便覧の科目に当たる' do
  assert_equal 'required_information', assessment_entry_category('知能101')
end

test '同じ科目番号の Course が2行あると要確認になる' do
  Course.create!(course_number: '知能101', name: 'プログラミング演習Ⅰ（別表記）', credits: 1)
  assert_includes assess.actual.review_notes.join, '科目番号'
end

test '自由入力計画科目は custom_category で区分が決まる' do
  course = Course.create!(name: '自由入力', credits: 2, custom_category: 'related')
  assert_equal 'related', course_category(course, @courses_by_number)
end

test '便覧が紐付いていない学生は設定画面になる' do
  @student.update!(curriculum: nil)
  get root_path
  assert_response :service_unavailable
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/controllers/student_workspace_test.rb`
Expected: FAIL

- [ ] **Step 3: マイグレーションと参照の付け替えを実装する**

`db/demo_enrollments.json` の `course_key` を `course_number` に置き換える（48件すべて番号を持つ。旧 `2024.json` のキー→番号の対応で機械置換）。`DemoData#import_courses` は `Course.find_or_initialize_by(course_number:, name:)` で引く。`PlanCoursesController` の `custom:<区分>:<乱数>` をやめ、`custom_category` に区分を入れる。

同じ科目番号の `Course` が複数あるときは、`StudentWorkspace#load_workspace` で見つけて `unresolved` 相当の要確認に回す（`EntryNormalizer#normalize_unresolved` の経路）。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails db:migrate && docker compose exec web bin/ci`
Expected: PASS（ゴールデンマスターを含む）

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "refactor: 便覧の科目を科目番号で引く"
```

---

### Task 11: 画面の章立てを display から読む

**Files:**
- Modify: `app/helpers/student_workspace_helper.rb`, `app/helpers/plans_helper.rb`
- Modify: `app/services/dashboard_metrics.rb`
- Modify: `app/controllers/plan_courses_controller.rb`
- Test: `test/services/dashboard_metrics_test.rb`, `test/controllers/dashboard_test.rb`

**Interfaces:**
- Consumes: `Curriculum#document['display']`、`#document['categories']`
- Produces:
  - `StudentWorkspaceHelper#planner_groups(curriculum)` — `display['groups']`（シンボルキーに変換して返す。ビューの `definition[:rows]` などの書き方を変えない）
  - `StudentWorkspaceHelper#category_label(category, curriculum)`
  - `PlansHelper#planner_subtotal_for(row_id, curriculum)`
  - `DashboardMetrics#initialize(assessment:, enrollments:, plans:, courses_by_number:, curriculum:)`、`#total` は `curriculum.document['display']['total_credits']` を使う
- 消すもの: `CATEGORY_LABELS` / `PLANNER_GROUPS` / `PLANNER_SUBTOTALS` / `GRADUATION_CREDITS` / `CHECK_DRIVEN_ROWS`（`CUSTOM_CATEGORIES` は Task 6 で処理済み）

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '章立ては便覧の display から来る' do
  assert_equal ['1. 共通教育', '2. 専門基礎教育', '3. 専門必修科目', '4. 専門選択科目'],
               planner_groups(curriculum).map { |group| group[:title] }
end

test '卒業総単位は便覧の display から来る' do
  curriculum.document['display']['total_credits'] = 124
  assert_equal 124, metrics.total(BigDecimal('0'), BigDecimal('0'))[:req]
end

test '区分の和名は便覧の categories から来る' do
  assert_equal '健康運動系', category_label('health', curriculum)
end

test 'credits_from_check の行はチェックの算入単位をそのまま使う' do
  # general_subtotal は自然系上限が効くので、区分の素の合計とは違う
  assert_equal BigDecimal('14'), metrics.row(row_named('general_subtotal'))[:earned]
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/dashboard_metrics_test.rb`
Expected: FAIL

- [ ] **Step 3: ヘルパーと `DashboardMetrics` を書き換える**

`row_check_status` / `category_credits` / `filter_by_categories` の中身は変えない。引数に `curriculum` が増えるだけ。ビュー（`plans/show.html.erb`、`dashboard/`）は定数の代わりにヘルパーを呼ぶように直す。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "refactor: 画面の章立てと区分名を便覧データから読む"
```

---

### Task 12: 卒業要件の確認画面を読み取り専用にする

**Files:**
- Modify: `app/views/requirements/show.html.erb`（441行を置き換え）
- Modify: `app/controllers/requirements_controller.rb`
- Test: `test/controllers/requirements_test.rb`

**Interfaces:**
- Consumes: `Curriculum#document['display']` / `['rules']` / `['categories']`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '便覧の章と必要単位が出る' do
  get requirements_path
  assert_select 'h3', text: /1\. 共通教育/
  assert_select 'body', text: /130/
end

test '要件を編集するボタンは出ない' do
  get requirements_path
  assert_select 'button[onclick]', count: 0
end

test '規則の型が未知の便覧でも画面は開く' do
  curriculum.document['rules'] << { 'id' => 'gpa', 'type' => 'gpa', 'label' => 'GPA' }
  get requirements_path
  assert_response :success
  assert_select 'body', text: /解釈できません/
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/controllers/requirements_test.rb`
Expected: FAIL

- [ ] **Step 3: ビューを書き直す**

`display['groups']` を章として並べ、各行に名前・補足・必要単位を出す。その下に `rules` を型ごとの一文で出す（`credit_sum`→「<label>：<区分名>の合計 N単位以上」、`any_of`→選択肢を並べる、など）。未知の型は「このアプリは解釈できません」と赤で出す。JavaScriptの編集機能は全部消す。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 卒業要件の確認画面を便覧データから描く"
```

**ここで第1部は終わり。2024年度の判定結果と画面は変わっていない。**

---

# 第2部 — 便覧を取り込む

---

### Task 13: アップロードと下書きの作成、ページの指定

**Files:**
- Create: `app/controllers/curricula_controller.rb`
- Create: `app/views/curricula/show.html.erb`, `app/views/curricula/_pages.html.erb`
- Modify: `app/views/requirements/show.html.erb`, `config/routes.rb`, `app/views/shared/_nav.html.erb`
- Test: `test/controllers/curricula_test.rb`

**Interfaces:**
- Produces:
  - ルート: `resources :curricula, only: %i[create show destroy]` に member で `publish`、`post 'pages/:page/read'`、`patch :update_courses`、`patch :update_rules`、`get 'page_image/:page'`
  - `Curriculum#pages` の要素: `{ "page" => 1, "kind" => "skip" | "courses" | "requirements", "status" => "pending" | "read" | "failed", "error" => nil, "text" => nil }`（`text` は Task 14 が埋める）
  - `CurriculaController` に `LocalAccessOnly`（`TimetableUploadsController` と同じ）

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'PDFを上げると下書きができてページ一覧が出る' do
  post curricula_path, params: { curriculum: { slug: 'x', admission_year: 2025,
    faculty_name: '工学部', department_name: '工学科 知能情報コース', file: pdf_fixture } }
  curriculum = Curriculum.last
  refute_predicate curriculum, :published?
  assert_equal 14, curriculum.pages.size
  assert_equal %w[skip], curriculum.pages.map { |page| page['kind'] }.uniq
end

test 'slug と年度と年度PDFが欠けていたら作らない' do
  assert_no_difference('Curriculum.count') { post curricula_path, params: { curriculum: { slug: '' } } }
end

test '下書きは消せる' do
  delete curriculum_path(draft)
  assert_nil Curriculum.find_by(id: draft.id)
end

test 'ページの種別を変えられる' do
  patch curriculum_path(draft), params: { pages: { '3' => 'requirements' } }
  assert_equal 'requirements', draft.reload.pages.find { |page| page['page'] == 3 }['kind']
end

test 'ナビは確認画面でも卒業要件の確認が選ばれている' do
  get curriculum_path(draft)
  assert_select 'a[aria-current=page]', text: '卒業要件の確認'
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/controllers/curricula_test.rb`
Expected: FAIL

- [ ] **Step 3: コントローラとビューを実装する**

`create` はPDFを受け、ページ数を数えて `pages` を `kind: "skip"` で埋め、`show` にリダイレクト。`requirements/show.html.erb` に便覧の一覧とアップロードフォームを足す（`course_registrations/index.html.erb` のフォームと同じ作り）。ナビの `active` 判定に `/curricula` を足す。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/controllers/curricula_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 便覧PDFのアップロードとページ指定を足す"
```

---

### Task 14: ページ画像とテキストを取り出す

**Files:**
- Create: `app/services/curriculum_import/page_source.rb`
- Modify: `app/models/curriculum.rb`, `app/controllers/curricula_controller.rb`
- Test: `test/services/curriculum_import/page_source_test.rb`

**Interfaces:**
- Consumes: `TimetableUpload` のページ画像化と同じ `gs` の呼び方
- Produces:
  - `CurriculumImport::PageSource.render_images(pdf_path, dir) => Integer`（ページ数）
  - `CurriculumImport::PageSource.page_texts(pdf_path) => [String]`（1要素＝1ページ）
  - `Curriculum.images_root`（テストで差し替えられるよう `TimetableUpload.images_root` と同じ作り）、画像は `<images_root>/<id>/p<n>.png`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'ページ数ぶんのPNGを作る' do
  assert_equal 2, PageSource.render_images(fixture_pdf, @dir)
  assert_path_exists @dir.join('p1.png')
end

test 'ページごとのテキストを返す' do
  texts = PageSource.page_texts(fixture_pdf)
  assert_equal 2, texts.size
  assert_includes texts.first, '知能'
end

test 'gs が失敗しても例外にせず空で返す' do
  assert_equal 0, PageSource.render_images(Rails.root.join('README.md'), @dir)
end

test '便覧を消すと画像も消える' do
  curriculum.destroy!
  refute_path_exists Curriculum.images_root.join(curriculum.id.to_s)
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_import/page_source_test.rb`
Expected: FAIL

- [ ] **Step 3: `PageSource` を実装する**

`render_images` は `gs -sDEVICE=png16m -r150`、`page_texts` は `gs -sDEVICE=txtwrite -dTextFormat=3` をページごとに（`-dFirstPage` / `-dLastPage`）。失敗は握りつぶして空を返す（取り込みの成否を画像化に引きずらせない）。`page_image` アクションは `TimetableUploadsController#page_image` と同じ `send_file`。

**画像とテキストの取り出しは、アップロードと同じリクエストの中で行う。** Task 13 が
`create` でページ数を数えてPDFを捨てているので、このタスクは同じ `create` の中に
画像生成とテキスト抽出を足し、そのあとで捨てる形にする。あとから読み直すPDFは残っていない。
Task 13 がインラインで書いたページ数の数え上げも、ここで `PageSource` に移す。

**元のPDFは保管しない。** アップロード時に画像とテキストを取り出したら消す。`pages` に入れるのはテキストで、以降の読み取りも確認画面もそれと画像だけで足りる。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_import/page_source_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 便覧PDFのページ画像とテキストを取り出す"
```

---

### Task 15: 読み取りの窓口とプロバイダ

**Files:**
- Create: `app/services/curriculum_reader.rb`
- Create: `app/services/curriculum_reader/gemini.rb`
- Create: `app/services/curriculum_reader/prompts.rb`
- Create: `app/services/curriculum_reader/schemas.rb`
- Test: `test/services/curriculum_reader_test.rb`

**Interfaces:**
- Produces:
  - `CurriculumReader.available? => Boolean`（`ENV['CURRICULUM_READER_API_KEY']` の有無）
  - `CurriculumReader.new(client: CurriculumReader::Gemini.new)`
  - `#read_requirements(text:, image_path:) => Hash`（`categories` / `rules` / `display`）
  - `#read_courses(text:, image_path:, categories:) => Hash`（`courses`）
  - `CurriculumReader::Error`（再試行しても駄目だったとき）
  - `Gemini#generate(prompt:, image_path:, schema:) => Hash`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'APIキーがなければ使えないと答える' do
  refute CurriculumReader.available?
end

test '科目表のプロンプトには確定した区分の一覧が入る' do
  client = stub_client { |prompt, _| @prompt = prompt; { 'courses' => [] } }
  CurriculumReader.new(client: client).read_courses(text: 't', image_path: nil, categories: %w[a b])
  assert_includes @prompt, 'a'
end

test '429 は待って数回やり直す' do
  client = failing_client(times: 2, status: 429)
  assert_equal({ 'courses' => [] }, reader(client).read_courses(text: 't', image_path: nil, categories: []))
  assert_equal 3, client.calls
end

test '再試行しても駄目なら Error' do
  assert_raises(CurriculumReader::Error) { reader(failing_client(times: 99, status: 429)).read_courses(...) }
end

test '200 でも本文がJSONでなければ Error' do
  assert_raises(CurriculumReader::Error) { reader(client_returning('<html>')).read_courses(...) }
end

test 'スキーマにない形が返ってきたら Error' do
  assert_raises(CurriculumReader::Error) { reader(client_returning({ 'rows' => [] })).read_courses(...) }
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_reader_test.rb`
Expected: FAIL

- [ ] **Step 3: 読み取りの窓口を実装する**

`CurriculumReader` は `client` を受け取るだけで、HTTPを知らない。再試行（429 と 5xx、指数バックオフ、3回まで）と戻り値の形の検査はここに置く。`Gemini` は `net/http` で `generateContent` を1回叩き、画像は base64 の `inline_data`。APIキーは `ENV['CURRICULUM_READER_API_KEY']`。テストは実APIを叩かない。

`Prompts` は要件表用と科目表用の2本。科目表用には区分の一覧を差し込む。`Schemas` は返す形のJSON Schema。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_reader_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 便覧を読むAIの窓口とGeminiのプロバイダを足す"
```

---

### Task 16: 1ページずつ読んで下書きに入れる

**Files:**
- Create: `app/services/curriculum_import/read_page.rb`
- Modify: `app/controllers/curricula_controller.rb`, `app/views/curricula/_pages.html.erb`
- Test: `test/services/curriculum_import/read_page_test.rb`, `test/controllers/curricula_read_test.rb`

**Interfaces:**
- Consumes: `CurriculumReader`（Task 15）、`PageSource`（Task 14）
- Produces: `CurriculumImport::ReadPage.new(curriculum, reader:).call(page) => Boolean`
  - 要件表のページ → `document['categories']` / `['rules']` / `['display']` に入れる
  - 科目表のページ → `document['courses']` に足す（既にある科目番号は上書きせず、Task 17 の重複として残す）
  - 読めたら `pages[n]['status']` を `"read"`、落ちたら `"failed"` と `error`

**Task 15 の修正で決まったこと（4点）。**

- **役割の受け渡し。** `read_requirements` は `roles`（キーと表示名）も返し、`read_courses` は
  `roles:` を受け取る。置き場所は `document['roles']` で、format_version 2 の任意欄として
  公開後も残す。キーだけなら `Catalogue#role_keys` が `rules` の `paths` から導けるが、
  モデルに渡す表示名（「微分積分学ＳＴⅠ」等）は導けないので保存が要る。
  2024年度の便覧には足さない（欄が無ければ規則から導く）。
- **区分の受け渡しと、順序を守れない場合。** 科目表の読み取りには `document['categories']`
  （要件表のページから溜まった分）を渡す。`read_courses` は `categories` が空なら
  `ArgumentError` を上げる（モデルに区分名を捏造させないため）。要件表を1ページも読む前に
  科目表を読もうとしたら、`ReadPage` はこれを rescue して**そのページだけ** `failed` と
  読める `error` にする。500 にしない。「全部読む」は要件表を先に読むので通常は起きないが、
  1ページ単位の読み取りはユーザー操作なので順序を強制できない。
- **1ページ分の断片の統合はこのタスクの仕事。** `total_credits`・`source`・`source_page`・
  `selectable`・`sources`・`key` を誰が入れるかをここで決める。`source_page` は読んだページ番号から
  `ReadPage` が入れる。
- **承認の注記がページを跨ぐ場合（このタスクの義務。懸念ではない）。**
  `requires_approval` は1ページずつ読むので、承認の注記が科目の行と別のページにあると、
  その科目は `false` になる。**`false` は寛容側**で、`EntryNormalizer` は真のときだけ関門を足すため、
  注記の見落としはそのまま単位の水増しになる（承認が要る科目の単位が無条件に算入され、不足が見えなくなる）。
  モデルが怪しいと気づけた場合は `review_reason` に書かせており、それは `metadata_review_reason` が
  科目ごと隔離するので安全側に倒れる。塞げていないのは、**そのページに手掛かりが何も無い**場合。
  全ページを見るこのタスクで、区分やページ単位の承認の注記を、後から該当科目の
  `requires_approval` に反映できるようにする。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '要件表のページを読むと規区分と規則が入る' do
  ReadPage.new(curriculum, reader: stub_reader).call(3)
  assert_equal %w[common_total], curriculum.document['rules'].map { |rule| rule['id'] }
  assert_equal 'read', page_status(curriculum, 3)
end

test '科目表のページを読むと科目が足される' do
  ReadPage.new(curriculum, reader: stub_reader).call(9)
  assert_equal 2, curriculum.document['courses'].size
end

test '読み取りが落ちてもそのページだけ failed になる' do
  refute ReadPage.new(curriculum, reader: raising_reader).call(9)
  assert_equal 'failed', page_status(curriculum, 9)
  assert_equal 'read', page_status(curriculum, 3)
end

test '読み取り直しても、確認済みにした科目は消えない' do
  confirm_course(curriculum, '知能103')
  ReadPage.new(curriculum, reader: stub_reader).call(9)
  assert confirmed?(curriculum, '知能103')
end

test 'kind が skip のページは読まない' do
  refute ReadPage.new(curriculum, reader: raising_reader).call(1)
end

test 'APIキーがなければ読み取りボタンを出さず、画面は手入力として使える' do
  CurriculumReader.stub(:available?, false) do
    get curriculum_path(draft)
    assert_response :success
    assert_select 'button', text: '全部読む', count: 0
    assert_select 'form[action=?]', update_courses_curriculum_path(draft)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_import/read_page_test.rb`
Expected: FAIL

- [ ] **Step 3: `ReadPage` と `read_page` アクションを実装する**

アクションは1ページ読んで、そのページの行だけ Turbo Stream で差し替える。画面の「全部読む」は Stimulus で、`kind` が `skip` でなく `status` が `read` でないページを上から順に `fetch` する（1つ終わってから次）。要件表のページを先に読む。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_import test/controllers/curricula_read_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 便覧を1ページずつ読んで下書きに入れる"
```

---

### Task 17: 機械的な突き合わせと、科目番号からの区分の推定

**Files:**
- Create: `app/services/curriculum_import/validation.rb`
- Create: `app/services/curriculum_import/category_inference.rb`
- Test: `test/services/curriculum_import/validation_test.rb`, `test/services/curriculum_import/category_inference_test.rb`

**Interfaces:**
- Consumes: `CourseNumber`（Task 2）
- Produces:
  - `CategoryInference.new(courses)` / `#inferred(number) => String | nil` / `#mismatches => [{number:, read:, inferred:}]`
  - `Validation.new(document) => #call => [{ scope: :course | :rule | :display, target: String, reason: String }]`
  - `Validation#blocking?` — 公開を止めるかどうか

壊れた規則の定義も弾く（Task 3 のレビューで判明。どれも「黙って充足」に倒れる）:
- `paths` が空、または `[[]]` のような空の経路を含む `one_of_paths`
- `expected_course_count` が 0、または必修科目が1つも無い `all_required`
- `categories` が空、または `categories[]` に無い区分を指す `credit_sum`
- `source_page` の無い規則
- 既知の型なのに、その型が要求するフィールドが欠けている規則
- `grouped_max` の `group_by` が `number_prefix` / `number_prefix_hundreds` / `field:<欄名>` のいずれでもない、または `field:` が指す欄を科目が持たない
- `exclude` の `number_prefix` が空、または正規化前の表記（全角・空白混じり）
- `exclude` に `reason` が無い
- `cap` の `credits` が負・非数・無限
- `rules` が名指しする役割を、どの科目も `roles` に持っていない（規則が永久に満たされない）
- 承認の注記の取りこぼし。`ApprovalNotes` の2つの警告はどちらもページの抽出テキストを見るが、
  テキスト層の無いスキャンPDFでは `entry['text']` が nil になり、両方とも死ぬ。
  `approval_notes` と `pages[n]['warnings']` をこの検証の入力にし、
  **テキストが空のページがあるのに承認の注記が1つも無い便覧**を疑わしいものとして挙げる
- `roles` に宣言されているのに、どの規則からも参照されない役割

- [ ] **Step 1: 推定の失敗するテストを書く**

```ruby
test '1つの区分にしか現れない接頭辞は、その区分を推定する' do
  # 人101..人105 がすべて humanities
  assert_equal 'humanities', inference.inferred('人106')
end

test '複数の区分にまたがる接頭辞は推定しない' do
  # 知能 が advanced と required_core にまたがる
  assert_nil inference.inferred('知能301')
end

test '百の位まで見れば決まるなら、それを使う' do
  # 外1xx は english、外2xx は foreign_language
  assert_equal 'english', inference.inferred('外103')
end

test '推定と読み取りが食い違う科目を mismatches に出す' do
  # 知能993 が工学融合にしか出ない接頭辞なのに course_required と読まれた
  assert_equal ['知能993'], inference.mismatches.map { |m| m[:number] }
end
```

- [ ] **Step 2: 突き合わせの失敗するテストを書く**

```ruby
test '科目番号の重複を出す' do
  assert_reason '同じ科目番号', duplicate_number_document
end

test '分類表にあって提供科目表にない科目を出す' do
  # number が空で name だけある科目
  assert_reason '提供科目表に行がない', orphan_document
end

test '必修の単位合計が all_required の required_credits と違えば出す' do
  assert_reason '必修の単位合計', mismatched_required_document
end

test 'check_ids が指す規則がなければ出す' do
  assert_reason '規則が見つかりません', dangling_check_id_document
end

test 'どの行にも出てこない区分があれば出す（公開を止める）' do
  result = Validation.new(uncovered_category_document)
  assert_reason '画面のどの行にも出てきません', result
  assert_predicate result, :blocking?
end

test 'excluded はどの行に出てこなくても止めない' do
  refute_predicate Validation.new(excluded_only_document), :blocking?
end

test '区分ごとの必要単位の合計が卒業総単位を超えていたら出す' do
  assert_reason '卒業算入の総単位を超えて', over_total_document
end
```

- [ ] **Step 3: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_import/`
Expected: FAIL

- [ ] **Step 4: 2つを実装する**

`CategoryInference` は `(接頭辞, 百の位)` → 区分 の集計を2段で作る。まず百の位まで含む鍵で1区分にしか現れない組を採り、残りを接頭辞だけの鍵で見る。**固定の対応表は持たない。** 渡された科目表から毎回作る。

`Validation#call` は設計書 §4 の9項目を順に見る。`blocking?` は「どの行にも出てこない区分がある」「`check_ids` / `categories` が存在しないものを指している」のときだけ true。

- [ ] **Step 5: 通ることを確認**

Run: `docker compose exec web bin/rails test test/services/curriculum_import/`
Expected: PASS

- [ ] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: 便覧の突き合わせと科目番号からの区分の推定を足す"
```

---

### Task 18: 要件表の確認画面

**Files:**
- Create: `app/views/curricula/_requirements_review.html.erb`
- Modify: `app/controllers/curricula_controller.rb`（`update_rules`）
- Test: `test/controllers/curricula_requirements_review_test.rb`

**Interfaces:**
- Consumes: `Validation`（Task 17）
- Produces: `PATCH /curricula/:id/update_rules` が `document['rules']` / `['categories']` / `['display']` を置き換える

- **人が直した規則・group・row を、読み直しから守るのはこのタスク。** Task 16 の
  `DraftMerge#forget_requirements` は、そのページが入れた規則と display を無条件に消して入れ直す。
  科目には `confirmed` の番人があるのに、規則側には無い（`draft_merge.rb` の該当箇所にコメントあり）。
  今は確認画面が無いので失われるものが無いだけで、このタスクが編集を足した瞬間に実害が出る。
  4つ必要: (1) 編集した規則・group・row に `confirmed` を付ける (2) `forget_requirements` に
  科目と同じ `&& !rule[CONFIRMED]` の番人を足す (3) `add_rules` は、保持された編集済みの id を
  再追加しない (4)「読み直す」が人の修正を捨てる前に警告する。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '区分ごとの必要単位の表が出る' do
  get curriculum_path(draft)
  assert_select 'tr', text: /共通教育 合計.*34/
end

test '判定に落とせない注釈は赤で出る' do
  assert_select '.needs-attention', text: /指導教員の承認/
end

test '章と行の並びを直せる' do
  patch update_rules_curriculum_path(draft), params: { display: { groups: [...] } }
  assert_equal '1. 共通教育', draft.reload.document['display']['groups'].first['title']
end

test '突き合わせの結果が画面に出る' do
  get curriculum_path(draft_with_dangling_check_id)
  assert_select 'body', text: /規則が見つかりません/
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/controllers/curricula_requirements_review_test.rb`
Expected: FAIL

- [ ] **Step 3: 画面を実装する**

上段に区分ごとの必要単位の表（`display` の章と行）、下段に注釈のカード。注釈は7つの型のどれかに割り当てるか「判定に反映しない」を選ぶ。`requires_approval` と外国人学生の特例は赤で理由つきに出す。突き合わせの結果を上部にまとめて出す。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/controllers/curricula_requirements_review_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 要件表の確認画面を足す"
```

---

### Task 19: 科目表の確認画面

**Files:**
- Create: `app/views/curricula/_courses_review.html.erb`
- Create: `app/views/curricula/_pdf_pane.html.erb`
- Modify: `app/controllers/curricula_controller.rb`（`update_courses`）
- Test: `test/controllers/curricula_courses_review_test.rb`

**Interfaces:**
- Consumes: `CategoryInference`（Task 17）、`PageSource` の `page_image`（Task 14）
- Produces: `PATCH /curricula/:id/update_courses` が1科目ぶんの値と `confirmed` を `jsonb_set` で更新する

**Task 16 からの申し送り（2点）。**

- **`update_courses` のフォームの確認は、このタスクが書く。** Task 16 のブリーフは
  `assert_select 'form[action=?]', update_courses_curriculum_path(draft)` を確認画面のテストに
  入れていたが、そのフォームも action も Task 19 のもので当時は存在しなかった。
  存在しない先を指すフォームを足すより移すほうが健全、と判断して移した。ここで必ず書く。
- **`selectable` は読み取り時に全科目 true になっている。** 便覧の「自分のコースの工学融合科目は
  選べない」のような例外は、この確認画面で人が落とす。見落とすと選べない科目が選べてしまうので、
  確認画面がその違いを目立たせること。
- **人が科目を確認したら `approval_by_note` の印を外す。** Task 18 の承認の注記の削除は、
  その注記が付けた科目（印を持つもの）だけを戻す。ところが注記が付けたあとに人がその科目を
  確認しても印は残るので、あとで注記を消すと、人が確認した科目の承認まで外れる。
  この画面が科目を確認するときに印を外せば、人の判断が注記の削除に巻き込まれない。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '区分ごとにまとめて出す' do
  get curriculum_path(draft)
  assert_select 'h4', text: /コース専門科目 ・ 45科目 ・ 必修31単位/
end

test '推定と食い違う科目を先頭に出す' do
  get curriculum_path(draft)
  assert_select '#course-review tr:first-child', text: /知能993/
end

test '確認チェックは1科目ずつ保存する' do
  patch update_courses_curriculum_path(draft), params: { number: '知能103', confirmed: true }
  assert confirmed?(draft.reload, '知能103')
  refute confirmed?(draft, '知能104')
end

test '同時に別の科目を確認しても取りこぼさない' do
  patch update_courses_curriculum_path(draft), params: { number: '知能103', confirmed: true }
  patch update_courses_curriculum_path(draft), params: { number: '知能104', confirmed: true }
  assert confirmed?(draft.reload, '知能103')
  assert confirmed?(draft, '知能104')
end

test '読み落とした科目を手で足せる' do
  patch update_courses_curriculum_path(draft),
        params: { number: '知能999', name: '追加', credits: 2, category: 'advanced', added_by_hand: true }
  assert_equal 1, draft.reload.document['courses'].count { |c| c['added_by_hand'] }
end

test 'PDFのページを並べて見られる' do
  assert_select 'img[src*="page_image"]'
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/controllers/curricula_courses_review_test.rb`
Expected: FAIL

- [ ] **Step 3: 画面を実装する**

区分ごとに見出し（区分名・科目数・必修単位）を付けて並べる。先頭に「推定と食い違う科目」の節を置く。PDFペインは `timetable_uploads` の `_pdf_pane` 相当をそのまま使う（貼り付く・倍率・幅に合わせる）。`update_courses` は `document` 全体を読み書きせず、`jsonb_set` でその科目の位置だけ更新する。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/rails test test/controllers/curricula_courses_review_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 科目表の確認画面を足す"
```

---

### Task 20: 公開する

**Files:**
- Modify: `app/controllers/curricula_controller.rb`（`publish`、`destroy`）
- Modify: `app/models/curriculum.rb`
- Test: `test/models/curriculum_publish_test.rb`

**Interfaces:**
- Produces:
  - `Curriculum#publish!` — `confirmed` と `pages` と `source_filename` を落とし、`published_at` を立て、ページ画像を消す
  - `Curriculum#publishable? => Boolean` / `#blocking_reasons => [String]`
  — 規則を持つのに `display` が無い便覧は公開できない。`Catalogue` は判定側の object なので
    load 時には求めない（規則だけの単体テストに display を書かせることになる）。
    「学生に出せる状態か」を決めるのはここ
  - `Student#curriculum_id` は公開済みの便覧しか指せない（モデルの検証）

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '確認し終えていない科目があれば公開できない' do
  refute_predicate draft_with_unconfirmed, :publishable?
end

test '止める突き合わせが残っていれば公開できない' do
  refute_predicate draft_with_uncovered_category, :publishable?
end

test '公開すると確認用の欄とページ画像が消える' do
  draft.publish!
  assert_predicate draft, :published?
  refute draft.document['courses'].first.key?('confirmed')
  assert_empty draft.pages
  refute_path_exists Curriculum.images_root.join(draft.id.to_s)
end

test '公開しても review_reason は残る' do
  draft.publish!
  assert draft.document['courses'].any? { |course| course['review_reason'].present? }
end

test '同じ slug と年度の公開済みが既にあれば公開できない' do
  refute_predicate second_draft_of_same_year, :publishable?
end

test '学生は下書きの便覧を指せない' do
  student.curriculum = draft
  refute_predicate student, :valid?
end

test '学生が指している便覧は消せない' do
  assert_no_difference('Curriculum.count') { delete curriculum_path(published_with_students) }
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/models/curriculum_publish_test.rb`
Expected: FAIL

- [ ] **Step 3: 公開を実装する**

公開のボタンは `publishable?` のときだけ押せる。押せないときは `blocking_reasons` を並べる。公開済みを直したいときのために、`show` に「複製して直す」を置き、`document` をコピーした下書きを作る（公開済みの行は書き換えない）。公開したら、その slug と年度の学生の `curriculum_id` を新しい行に付け替えるかどうかを確認して1本の `update_all` で切り替える。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 確認し終えた便覧を公開する"
```

---

# 第3部 — 残り

---

### Task 21: 指導教員の承認を学生が答えられるようにする

**Files:**
- Modify: `app/controllers/concerns/student_workspace.rb`, `app/controllers/plan_courses_controller.rb`
- Create: `app/controllers/approvals_controller.rb`
- Modify: `app/views/plans/_enrollment_card.html.erb`, `_plan_card.html.erb`, `config/routes.rb`
- Test: `test/controllers/approvals_test.rb`

**Interfaces:**
- Consumes: `planned_courses.approval_confirmed`（Task 10 のマイグレーションで追加済み）
- Produces: `PATCH /approvals` が `student_courses` か `planned_courses` の `approval_confirmed` を更新する。`StudentWorkspace#planned_entry` の `approved:` は `plan.approval_confirmed` を渡す。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '承認が要る科目の行に、承認あり／なしが出る' do
  get plan_path
  assert_select 'button', text: '承認あり'
end

test '承認が要らない科目には出ない' do
  assert_select "[data-course='知能103'] button", text: '承認あり', count: 0
end

test '承認ありと答えると判定が確定する' do
  patch approvals_path, params: { kind: 'plan', id: plan.id, approved: true }
  refute_equal :needs_review, assess.projected.status
end

test '未回答の予定は見込み判定でも要確認のまま' do
  assert_equal :needs_review, assess.projected.status
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/controllers/approvals_test.rb`
Expected: FAIL

- [ ] **Step 3: 承認の入力を実装する**

`requires_approval` が true の科目の行にだけ「承認あり／なし／未回答」を出す。押した時点で保存して Turbo でその行を差し替える。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 指導教員の承認を学生が答えられるようにする"
```

---

### Task 22: 2025年度のデモ学生

**Files:**
- Modify: `app/services/demo_account.rb`, `app/services/demo_data.rb`, `db/seeds.rb`
- Create: `db/demo_enrollments_2025.json`
- Test: `test/services/demo_data_test.rb`

**Interfaces:**
- Produces: `DemoAccount.students => [Student]`。既存の `DemoAccount.student` は1人目を返す（呼び口を壊さない）。2人目は 2025年度入学、`curriculum` は 2025年度の便覧。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '2025年度入学のデモ学生ができる' do
  assert_equal [2024, 2025], DemoAccount.students.map(&:admission_year).sort
end

test '2025年度の学生は2025年度の便覧で判定される' do
  assert_equal 2025, DemoAccount.students.last.curriculum.admission_year
end

test '2025年度の便覧がなければ2025年度の学生は作らない' do
  Curriculum.where(admission_year: 2025).destroy_all
  assert_equal 1, DemoData.load!.size
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/demo_data_test.rb`
Expected: FAIL

- [ ] **Step 3: デモ学生を2人にする**

`DemoAccount` の `EMAIL` / `ADMISSION_YEAR` の1人固定をやめ、学生の定義を配列にする。2025年度の便覧は、実物の `docs/kogaku_chinot_y25.pdf` を取り込んで公開したものを `config/curricula/intelligent_informatics/2025.json` に書き出し、seedに入れる。

- [ ] **Step 4: 2025年度を実際に通す**

Run: 開発環境でアプリを開き、`/requirements` から `docs/kogaku_chinot_y25.pdf` を取り込んで公開し、2025年度のデモ学生でダッシュボードと履修計画表を見る。
Expected: 章の見出しが「共通教育 34以上」「専門教育 90以上」になり、卒業総単位が124になる。2024年度の学生の画面は変わっていない。

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 2025年度の便覧とデモ学生を足す"
```
