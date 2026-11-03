# 卒業要件画面の作り直し 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 卒業要件の確認画面を「対象を選んでから見る」形にし、取り込みの入口も含めて、ITに詳しくない学部事務の人が迷わず使える画面にする。

**Architecture:** `/requirements` は学生の便覧を即座に出すのをやめ、学部・学科コース・入学年度を選ぶ画面にする。選んだ組み合わせの状態（公開済み・下書き・未作成）で出し分ける。選択後の表示は卒業ダッシュボードのカードに揃え、科目表も同じ画面で読める。取り込みフォームは識別名の入力をやめ、プルダウンで選ばせる。

**Tech Stack:** Rails 8.1 / Hotwire / Tailwind（既存どおり。gemを足さない）

**Spec:** `docs/superpowers/specs/2026-10-29-curriculum-import-design.md`（便覧取り込みの設計。この計画はその画面部分の作り直し）

## Global Constraints

- gemを足さない。ジョブ基盤を入れない。
- `test/fixtures/files/graduation_golden_2024.json` は一切変えない。判定が動いていない証拠なので、動いたら退行として報告する。
- `config/curricula/intelligent_informatics/2024.json` は Task 2 で学部名・学科コース名だけを足す。それ以外は変えない。規則・科目・display・total_credits は1文字も変えない。
- 画面は既存の `LocalAccessOnly` / `local_demo_access?` の守りを外さない。認証は範囲外。
- コメントは日本語で、なぜそうしたかを書く。周りの密度に合わせる。
- テストは1ファイルずつ走らせる。並列で2つ走らせるとコンテナ内のテストDBが壊れる。触っていないファイルが落ちたら、単独で回し直してから信じる。

## Review Focus

- 学生が自分の便覧をすぐ見られなくなる（選択が必須になる）ことの受け入れ。ダッシュボードから来た学生が迷わないか。
- 選択の状態をURLに持たせるので、ブックマークや再読込で壊れないか。
- 学部名・学科コース名を文書に足すことで、公開の語彙検査（`PublishedDocument`）や `Catalogue` の読み込みが壊れないか。
- プルダウンに無い学部・コースを初めて登録する経路が、本当に通るか（逃げ道が機能するか）。
- 識別名を自動生成したとき、既存の便覧と衝突しないか。部分一意索引 `(slug, admission_year) WHERE published_at IS NOT NULL` を破らないか。

---

### Task 1: デモ学生の切り替えを消す

**Files:**
- Modify: `app/views/shared/_nav.html.erb`, `app/controllers/concerns/student_workspace.rb`, `app/services/demo_account.rb`, `config/routes.rb`
- Delete: `app/controllers/demo_switch_controller.rb`, `test/controllers/demo_switch_test.rb`
- Test: `test/services/demo_account_test.rb`

**Interfaces:**
- Consumes: なし
- Produces: `DemoAccount.student`（変更なし。常に1人目=2024年度）、`DemoAccount.students`（`DemoData.load!` が使い続ける）

上のタブの年度切り替えは「おかしい」という指摘で消す。裏にある仕組み（`DemoSwitchController`・`session[:demo_admission_year]`・`StudentWorkspace#demo_switch_student`・`DemoAccount.available_students` / `student_for_year`）も使われなくなるので一緒に消す。**消さないもの:** `DemoAccount::Definition`・`DemoAccount::STUDENTS`・`DemoAccount.students`・`DemoAccount.student`。`DemoData.load!` が2人のデモ学生を投入し続ける作りは変えない（2025年度の学生はDBに残るが、学生としての画面は出せなくなる。これは承知のうえの判断）。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# test/services/demo_account_test.rb
test 'student は常に2024年度のデモ学生を返す' do
  DemoData.load!
  assert_equal 2024, DemoAccount.student.admission_year
end

test '切り替えの口は無くなっている' do
  assert_not DemoAccount.respond_to?(:student_for_year)
  assert_not DemoAccount.respond_to?(:available_students)
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/services/demo_account_test.rb`
Expected: FAIL（`student_for_year` がまだ在る）

- [ ] **Step 3: 消す**

ナビの切り替え・コントローラ・ルート・`demo_switch_student`・`available_students`・`student_for_year` を消す。`student_for` / `find_student` は `.student` だけが使うので、1つにまとめ直してよい（`.student` の例外の文面は変えない）。`session[:demo_admission_year]` を読む場所が無くなることを `grep` で確かめる。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS。ナビに切り替えが出ないこと、既存の `DemoAccount.student` 依存のテストが無傷であることを確かめる。

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "fix: 上のタブからデモ学生の切り替えを消す"
```

---

### Task 2: 便覧の文書に学部名と学科・コース名を持たせる

**Files:**
- Modify: `config/curricula/intelligent_informatics/2024.json`, `config/curricula/intelligent_informatics/2025.json`
- Modify: `app/models/curriculum.rb`（`seed_from_file`）, `app/services/curriculum_import/published_document.rb`（`TOP_LEVEL_KEYS`）
- Test: `test/models/curriculum_test.rb`, `test/services/curriculum_import/published_document_test.rb`（無ければ既存の公開のテストに足す）

**Interfaces:**
- Consumes: なし
- Produces: 文書の最上位に `faculty_name` と `department_name`（どちらも文字列）。`seed_from_file` がこの2つを列にも写す。公開しても落ちない。

プルダウンの選択肢は学部名・学科コース名で作る。いまは取り込みフォームから作った便覧にしか入っておらず、ファイルから seed した2024年度の便覧は両方 nil。文書に持たせれば、seed でも取り込みでも同じ値が入り、書き出して読み直しても失われない。`department`（= slug、機械用の識別名）とは別物なので、名前で取り違えないこと。

**2024年度に入れる値:** `faculty_name` は `"工学部"`、`department_name` は `"工学科 知能情報コース"`（2025年度と同じ表記に揃える。`title` の「琉球大学工学部工学科 知能情報コース」から機械的に切り出さない。表記ゆれの元になる）。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'ファイルから読み込んだ便覧にも学部名と学科コース名が入る' do
  curriculum = Curriculum.seed_from_file(Rails.root.join('config/curricula/intelligent_informatics/2024.json'))

  assert_equal '工学部', curriculum.faculty_name
  assert_equal '工学科 知能情報コース', curriculum.department_name
end

test '公開しても学部名と学科コース名は文書に残る' do
  document = CurriculumImport::PublishedDocument.build(draft_document, slug: 'x', admission_year: 2025)

  assert_equal '工学部', document['faculty_name']
  assert_equal '工学科 知能情報コース', document['department_name']
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/models/curriculum_test.rb`
Expected: FAIL

- [ ] **Step 3: 足す**

2つのJSONに `faculty_name` と `department_name` を足す（他の欄は触らない）。`TOP_LEVEL_KEYS` に2つを足す。`seed_from_file` が文書から列へ写す。取り込みの公開でも、列の値が文書に入るようにする（どちらの経路でも文書と列が一致する）。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS。あわせて `git diff` で `test/fixtures/files/graduation_golden_2024.json` が無変更であること、`2024.json` の差分が2行の追加だけであることを確かめる。

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 便覧の文書に学部名と学科・コース名を持たせる"
```

---

### Task 3: 卒業要件の確認画面を、対象を選んでから見る形にする

**Files:**
- Modify: `app/controllers/requirements_controller.rb`, `app/views/requirements/show.html.erb`
- Create: `app/views/requirements/_selector.html.erb`, `app/views/requirements/_empty.html.erb`
- Test: `test/controllers/requirements_test.rb`

**Interfaces:**
- Consumes: `Curriculum`（Task 2 で学部名・学科コース名が入る）
- Produces: `GET /requirements?faculty=工学部&department=工学科 知能情報コース&admission_year=2025` が、その組み合わせの便覧を出す。指定が無ければ選択だけを出す。

いまは `StudentWorkspace` を取り込んでいて、ログイン中のデモ学生の便覧をいきなり出す。これをやめ、選択してから出す。`StudentWorkspace` の代わりに `LocalAccessOnly` を使う（守りの強さは変えない）。選択はクエリパラメータで持つ（再読込・ブックマークで壊れない。セッションに隠さない）。

**選んだ組み合わせの状態で3つに分ける:**
- 公開済みがある → 卒業要件を出し、「この卒業要件を編集する」ボタンを添える（押すと既存の複製して直す＝`duplicate` に飛ぶ）
- 下書きがある → 「下書きの確認を続ける」で `/curricula/:id` に飛ばす
- どちらも無い → 「この年度の便覧はまだありません」と、PDFから作り始める導線

**消すもの:** 「公開済みの便覧」「下書き」のカード一覧。選択で辿れるので要らない（指摘2・3）。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '何も選んでいないときは、卒業要件を出さずに選択だけ出す' do
  get requirements_path, env: local_env

  assert_response :success
  assert_select 'select[name=admission_year]'
  assert_select '[data-total-credits]', count: 0
end

test '選ぶとその年度の卒業要件が出る' do
  get requirements_path(faculty: '工学部', department: '工学科 知能情報コース', admission_year: 2024), env: local_env

  assert_select '[data-total-credits]', text: /130/
end

test '公開済みを選ぶと、編集するボタンが出る' do
  get requirements_path(faculty: '工学部', department: '工学科 知能情報コース', admission_year: 2024), env: local_env

  assert_select 'form[action=?]', duplicate_curriculum_path(published_curriculum)
end

test '便覧の無い年度を選ぶと、PDFから作る導線が出る' do
  get requirements_path(faculty: '工学部', department: '工学科 知能情報コース', admission_year: 2030), env: local_env

  assert_select 'form[action=?]', curricula_path
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/controllers/requirements_test.rb`
Expected: FAIL

- [ ] **Step 3: 選択画面にする**

`RequirementsController#show` が、学部・学科コース・入学年度の選択肢（既存の便覧から作る）と、選ばれた組み合わせの便覧を用意する。選ばれていなければ便覧を引かない。`@catalogue` を作るのは便覧が決まったときだけ（決まっていないのに `Catalogue.new` を呼ばない）。

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 卒業要件の確認を、対象を選んでから見る形にする"
```

---

### Task 4: 選んだ便覧の見せ方を整える

**Files:**
- Modify: `app/views/requirements/show.html.erb`
- Create: `app/views/requirements/_courses.html.erb`
- Modify: `app/helpers/requirements_helper.rb`（無ければ作る）
- Test: `test/controllers/requirements_test.rb`

**Interfaces:**
- Consumes: Task 3 の `@curriculum`
- Produces: 画面に科目表の節が出る。判定の規則の節は、上のカードと重複しないものだけになる。

**3つ直す（指摘4・5・6）:**

1. **卒業ダッシュボードのカードUIに揃える。** いまの章の節は独自の作りになっている。ダッシュボード（`app/views/dashboard/show.html.erb`）の区分カードと同じ見た目・同じ余白・同じ角丸にする。先にダッシュボードの該当部分を読んでから書くこと。
2. **科目表を足す。** 公開後の便覧の科目表は、いまどの画面からも見られない（下書きの確認画面にしかない）。区分ごとにまとめた読み取り専用の節を足す。1区分ごとに、科目番号・科目名・単位数・必修かどうかを出す。484行あるので、区分ごとに折りたたむ（`<details>`）。
3. **判定の規則を間引く。** いまは上のカードと1対1で同じことを言う規則（「健康運動系の合計 2単位以上」＝上のカードの「健康運動系 2単位」）まで並べていて、同じ内容が2回出ている。**上のカードから読み取れない規則だけ残す**：`one_of_paths`（微分積分の系列選択など）・`any_of`（外国語の選択経路）・`cap`（算入上限）・`exclude`（算入しない）・複数の区分をまとめて数える `credit_sum`。1つの区分だけを数える `credit_sum` で、その区分が上の行に出ているものは出さない。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '科目表が区分ごとに出る' do
  get requirements_path(**selection_2024), env: local_env

  assert_select 'details summary', text: /人文系/
  assert_select '[data-course-number]', text: '人101', count: 1
end

test '上のカードと同じことを言うだけの規則は、規則の節に出さない' do
  get requirements_path(**selection_2024), env: local_env

  # 「健康運動系の合計 2単位以上」は上の行に出ているので、規則の節には出さない
  assert_select '#judgement-rules', text: /健康運動系の合計/, count: 0
  # 系列の選択・算入上限・算入しない規則は、カードからは読み取れないので残す
  assert_select '#judgement-rules', text: /微分積分学/
  assert_select '#judgement-rules', text: /自然系は卒業算入の上限/
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/controllers/requirements_test.rb`
Expected: FAIL

- [ ] **Step 3: 直す**

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add -A
git commit -m "feat: 卒業要件の画面に科目表を足し、重複する規則を間引く"
```

---

### Task 5: 取り込みフォームから識別名を消し、プルダウンにする

**Files:**
- Modify: `app/views/requirements/show.html.erb`（取り込みフォーム）, `app/controllers/curricula_controller.rb`
- Modify: `app/models/curriculum.rb`（識別名の自動生成）
- Test: `test/controllers/curricula_test.rb`, `test/models/curriculum_test.rb`

**Interfaces:**
- Consumes: Task 2 の学部名・学科コース名
- Produces: 取り込みフォームは `curriculum[faculty_name]` / `curriculum[department_name]` / `curriculum[admission_year]` を選択で受け取る。`curriculum[slug]` は送られない。`Curriculum` が学部名・学科コース名から識別名を決める。

**識別名（slug）の入力欄を無くす（指摘7）。** あれはDBの内部キーで、人が見る必要のないもの。学部名と学科コース名が決まれば決まるようにする。
- 同じ学部名・学科コース名の便覧が既にあれば、**その識別名をそのまま使う**（同じ課程の別の年度として並ぶ）。
- 無ければ新しく作る。日本語を機械的にローマ字へ直す手立ては無い（gemを足さない）ので、**人が読む必要のない形**でよい（例: `program_1`・`program_2` と連番、または短いランダム文字列）。衝突しないことだけを保証する。

**3つの欄をプルダウンにする（指摘8）。**
- 入学年度: 今年の前後の妥当な範囲（例: 今年-6 〜 今年+1）。
- 学部名・学科コース名: 既存の便覧にある組み合わせから作る。**「その他（新しく登録する）」を選んだときだけ**、自由入力の欄を出す（初めての学部・コースを登録する経路を塞がない）。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '識別名を送らなくても、学部名と学科コース名から決まる' do
  post curricula_path, params: { curriculum: { faculty_name: '工学部', department_name: '工学科 知能情報コース',
                                               admission_year: 2026, file: pdf_upload } }, env: local_env

  assert_equal 'intelligent_informatics', Curriculum.order(:id).last.slug
end

test '新しい学部・コースには、新しい識別名が作られる' do
  post curricula_path, params: { curriculum: { faculty_name: '農学部', department_name: '亜熱帯農林環境科学科',
                                               admission_year: 2026, file: pdf_upload } }, env: local_env

  created = Curriculum.order(:id).last
  assert_predicate created.slug, :present?
  assert_not_equal 'intelligent_informatics', created.slug
end

test 'フォームに識別名の入力欄は無い' do
  get requirements_path, env: local_env

  assert_select 'input[name=?]', 'curriculum[slug]', count: 0
  assert_select 'select[name=?]', 'curriculum[admission_year]'
end
```

- [ ] **Step 2: 失敗を確認**

Run: `docker compose exec web bin/rails test test/controllers/curricula_test.rb`
Expected: FAIL

- [ ] **Step 3: 直す**

- [ ] **Step 4: 通ることを確認**

Run: `docker compose exec web bin/ci`
Expected: PASS

- [ ] **Step 5: 実際に画面で通す**

Run: 開発環境でアプリを開き、`/requirements` で学部・コース・年度を選び、2024年度と2025年度の卒業要件と科目表が出ること、編集するボタンが効くこと、新しい年度を選ぶとPDFの取り込みに進めることを確かめる。
Expected: 識別名を一度も入力せずに、取り込みから公開まで進める。

- [ ] **Step 6: コミット**

```bash
git add -A
git commit -m "feat: 取り込みフォームから識別名を消し、プルダウンにする"
```
