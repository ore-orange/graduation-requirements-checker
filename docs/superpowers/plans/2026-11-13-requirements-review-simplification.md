# 便覧の下書き編集画面の簡素化 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `/curricula/:id` の確認画面から、持ち主の行・章・枠がもう出している決まりの箱を消し、残る決まりをアプリ内部の語彙なしの日本語にし、科目表と「読むページ」を見られる量にする。

**Architecture:** 文書(`document`)の形は変えない。変えるのは画面(view)と、画面とフォームの間の組み立て(`RequirementsReview` presenter / `RequirementsEdit` の保存)だけ。「箱を隠すか」の判定は新しい小さなクラス1つ(`RequirementsReview::Mirror`)に集め、画面と保存の両方がそれを引く(2か所で別々に判定すると、隠した箱の値を誰も書かない穴ができる)。

**Tech Stack:** Rails 8 / Hotwire(Turbo + Stimulus) / Tailwind v4 / PostgreSQL 17 / Minitest。テストは Docker の開発コンテナで動かす。

**Spec:** [docs/superpowers/specs/2026-11-13-requirements-review-simplification-design.md](../specs/2026-11-13-requirements-review-simplification-design.md)

## Global Constraints

- **判定結果を変えない。** `test/fixtures/files/graduation_golden_2024.json` は1バイトも変えない。変わったら実装が間違っている。
- **触らずに保存したら、文書が1バイトも変わらず「人が確認した」印も付かない。** 既存テスト(`requirements_protection_test.rb` の「触らずに保存しても…」)が守っている。新しい書き戻しも、値が実際に変わったときだけ走ること。
- **同名パラメータを2か所から送らない。** `RequirementsReview#claim_rule_box?` が1画面に1組だけを許す。隠した箱は欄を持たないので、持ち主が書く側になる。
- **`number_patterns` を画面から消さない。**
- 画面の本文・入力欄・チップ・ボタンの既定は `text-sm`。`text-xs` に残すのは見出しの脇の補足(「人が確認した」「内数」「◯件」)だけ。
- アプリ内部の語彙(役割キー・`field:language`・`number_prefix`・区分キー・規則の id)を画面に出さない。
- テストの実行は `docker compose exec -T web bin/rails test <path>`。着手前の全体は 1392 runs / 0 failures。

## Review Focus

仕様が黙っているが、人が触ると壊れる入力。各行の末尾に、そのテストを持つタスクを書く。

1. **隠れた決まりを指す持ち主が、同じ保存の中で消される**(`_destroy`)。行を消したとき、その行だけが指していた決まりも消えるのが既存の `drop_orphaned_rules` の動き。書き戻しが、消えた持ち主の値を消えた決まりに書こうとして落ちてはいけない → Task 5。
2. **行の区分を空にする。** 区分0個の行は、章の合併が変わるうえ、`categories` が空の `credit_sum` は何も数えない。書き戻しで空集合を書いてよいか → Task 5。
3. **経路に、科目表に無い科目番号が選ばれる。** 選択肢は科目表から作るが、保存できなかった送信を戻すときに古い値が残りうる → Task 7。
4. **同じ科目を2つの経路に選ぶ。** `OneOfPaths#mixed?` が重複算入として全員を要確認にする。画面が止めるのか、通して判定に任せるのか → Task 7。
5. **ページ画像が無い下書きでサムネイルを出す。** `page_image_data` は nil を返し `head :not_found`。壊れた `<img>` を並べない → Task 1。

---

## File Structure

**新しく作る**

| ファイル | 責任 |
|---|---|
| `app/services/curriculum_import/requirements_review/mirror.rb` | 「この決まりは持ち主と同じことを言っているか」の判定ひとつ。画面と保存が共通で引く |
| `app/services/curriculum_import/requirements_edit/mirror_writeback.rb` | 持ち主の値を、隠れた決まりに書き戻す |
| `app/helpers/requirement_course_chips_helper.rb` | 経路の科目チップ(区分で絞って足す) |
| `app/javascript/controllers/section_toggle_controller.js` | 科目表の節の開閉 |
| `app/views/curricula/_requirements_rule_line.html.erb` | 残った決まり1つを、日本語の1行で出す |

**直す**

| ファイル | 何を |
|---|---|
| `_pages.html.erb` / `_page_row.html.erb` | 手順①の見出し、サムネイル |
| `show.html.erb` | 節の番号付き見出しと、上のリンク |
| `_requirements_review.html.erb` | 出典を1箇所に、説明を短く |
| `_requirements_table` / `_group` / `_frame` / `_row` | 箱を隠す、単位の欄を読むだけにする、`…` に label/detail |
| `_requirements_rule.html.erb` | 出典の行を消す、型名を出さない |
| `_requirements_rule_paths.html.erb` | 役割チェック → 科目チップ |
| `_requirements_rule_condition.html.erb` | 種類の言い換え、`group_by` の選択肢 |
| `_courses_review.html.erb` | 節を畳む、一括確認を中へ |
| `_requirements_categories.html.erb` | 区分キーを出さない |
| `_requirements_excludes.html.erb` | ラベルの重なり |
| `requirements_review_helper.rb` | `credit_slot` に読むだけの形、`group_by` の選択肢、型名を出す場所を絞る |
| `requirements_review.rb` | `Mirror` を引く口、`source_pages`、経路の科目の選択肢 |
| `requirements_edit.rb` | `MirrorWriteback` を `apply_sections` に足す |
| `requirements_edit/nested_coercion.rb` | 経路を科目キーで受け、役割に直す |
| `draft_merge.rb` | 読み直しで既存の役割を消さない |
| `rule_sentence_helper.rb` | `GROUP_BY_NAMES` を「提供コース」に |
| `app/assets/tailwind/application.css` | `.rv-*` / `.cr-chip` の文字サイズ |

---

## Task 1: 「読むページ」を手順①にし、ページのサムネイルを出す

仕様 §7。ほかのタスクと独立。

**Files:**
- Modify: `app/views/curricula/_pages.html.erb`, `app/views/curricula/_page_row.html.erb`, `app/views/curricula/show.html.erb`, `app/views/curricula/_requirements_review.html.erb:6`, `app/views/curricula/_courses_review.html.erb:6`, `app/views/curricula/_publish.html.erb`
- Test: `test/controllers/curricula_test.rb`

**Interfaces:**
- Consumes: `page_image_curriculum_path(curriculum, page_number)`(既存ルート)、`Curriculum#page_image_data`(画像が無ければ nil)
- Produces: なし

- [ ] **Step 1: 失敗するテストを書く**

`test/controllers/curricula_test.rb` に3つ。

```ruby
test '読むページは、手順の①として出る' do
  get curriculum_path(draft), env: ENV_LOCAL
  assert_select 'h3', text: /①\s*PDFを読み取る/
  assert_select 'h3', text: /②\s*要件表を確認する/
  assert_select 'h3', text: /③\s*科目表を確認する/
  assert_select 'h3', text: /④\s*公開する/
end

test 'ページの行に、そのページのサムネイルが出る' do
  # 画像を持つ下書き(page_image_data が値を返す)
  assert_select 'li#... img[src=?][loading=?]', page_image_curriculum_path(draft, 1), 'lazy'
end

test '画像が無いページには、壊れた img を出さない' do
  # page_image_data が nil の下書き
  assert_select 'li#... img', false
end
```

`page_image_data` がどう画像を持つかは `app/models/curriculum.rb:173` を読み、既存の `curricula_read_test.rb` が画像付きの下書きをどう作っているかに合わせる。

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose exec -T web bin/rails test test/controllers/curricula_test.rb`
Expected: FAIL（見出しが「読むページ」のまま、img が無い）

- [ ] **Step 3: 実装する**

- `_pages.html.erb` の `<h3>` を `① PDFを読み取る` に。説明は2文に削る: 「便覧PDFのページを1枚ずつAIに読ませます。どのページが要件表で、どのページが科目表かは便覧ごとに違うので、サムネイルを見て指定してください。」
- `show.html.erb` の「確認する場所:」のリンク文言を `① PDFを読み取る` `② 要件表を確認する` `③ 科目表を確認する` `④ 公開する` に合わせる。
- `_requirements_review.html.erb` / `_courses_review.html.erb` / `_publish.html.erb` の `<h3>` に番号を足す。
- `_page_row.html.erb`: ページ番号の左に `image_tag page_image_curriculum_path(curriculum, page['page']), loading: 'lazy'`、幅は `w-16`、枠線付き。`Curriculum#page_image?(page)` のような述語を model に足し、画像が無いページでは `img` を出さない。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `docker compose exec -T web bin/rails test test/controllers/curricula_test.rb`
Expected: PASS

- [ ] **Step 5: 全体のテスト**

Run: `docker compose exec -T web bin/rails test`
Expected: 0 failures（見出し文言に依存していた既存テストがあれば直す）

- [ ] **Step 6: コミット**

```bash
git add app/views/curricula app/models/curriculum.rb test/controllers/curricula_test.rb
git commit -m "feat: 読むページを手順①にし、ページのサムネイルを出す"
```

---

## Task 2: 科目表の節を畳み、一括確認を中に移す

仕様 §6。ほかのタスクと独立。

**Files:**
- Create: `app/javascript/controllers/section_toggle_controller.js`
- Modify: `app/views/curricula/_courses_review.html.erb:54-83`
- Test: `test/controllers/curricula_courses_review_test.rb`

**Interfaces:**
- Consumes: `CoursesReview#sections`(`Section` は `key/title/total/required_credits/counted/selectable/unselectable/rows`)、`#section_pending`、`#section_revision`
- Produces: なし

節は1つの `<table>` の `<tbody>` で、上に `pdf_pane` のスティッキー行がある。`<details>` では囲めないので、**科目の `<tbody>` に `hidden` を付け、見出しのボタンで外す**。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '区分の節は、既定で畳まれている' do
  show_courses(draft)
  assert_select "tbody##{course_dom_id(...)}[hidden]"       # 科目の行
  assert_select 'tbody#course-category-humanities', 1        # 見出しは出ている
end

test '最初に見る科目は、畳まない' do
  assert_select 'tbody#course-first-look[hidden]', false
end

test '見出しに、その区分の未確認の件数が出る' do
  assert_select 'th', text: /人文系 ・ 3科目 ・ 必修0単位 ・ 未確認3件/
end

test 'まとめて確認するボタンは、畳んだ見出しではなく開いた中にある' do
  assert_select 'tbody#course-category-humanities th button[formaction]', false
  assert_select "tbody[hidden] button[formaction*=?]", 'bulk_confirm'
end
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose exec -T web bin/rails test test/controllers/curricula_courses_review_test.rb`
Expected: FAIL

- [ ] **Step 3: `section_toggle_controller.js` を書く**

`toggle(event)`: ボタンの `data-section` が指す `tbody` 群の `hidden` を反転し、ボタンの `aria-expanded` を合わせる。JavaScript が無くても中身に届くよう、見出しのボタンは `<summary>` ではなく `aria-expanded` 付きの `<button>` にし、`hidden` は Stimulus の `connect()` で付ける（サーバーは `hidden` を書かない。JS が無ければ全部開いたまま＝いまと同じ）。

- [ ] **Step 4: `_courses_review.html.erb` を直す**

- 節の見出しに件数(`section.total`・`section.required_credits`・`review.section_pending(section.key).size`)と開閉ボタン。
- 「まとめて確認する」ボタンを、見出しの `th` から科目の `tbody` の先頭行に移す。確認の文言(`turbo_confirm`)はそのまま。
- 「最初に見る科目」の節は畳まない。

- [ ] **Step 5: テストが通ることを確かめる**

Run: `docker compose exec -T web bin/rails test test/controllers/curricula_courses_review_test.rb`
Expected: PASS

- [ ] **Step 6: 全体のテストとコミット**

```bash
docker compose exec -T web bin/rails test
git add app/views/curricula/_courses_review.html.erb app/javascript/controllers/section_toggle_controller.js test/controllers/curricula_courses_review_test.rb
git commit -m "feat: 科目表の区分の節を畳み、まとめて確認を節の中に移す"
```

---

## Task 3: 「持ち主と同じことを言っている決まり」の判定

仕様 §1。Task 4・5 の土台。画面にはまだ出さない。

**Files:**
- Create: `app/services/curriculum_import/requirements_review/mirror.rb`
- Test: `test/services/curriculum_import/requirements_review/mirror_test.rb`

**Interfaces:**
- Consumes: `CurriculumImport::Validation::Input`(`#categories` `#rules` `#groups` `#rows` `#subtotals` `#display`)
- Produces:
  - `Mirror.new(input)`
  - `#duplicate?(rule, owner_kind, owner, blocked: false) -> Boolean` — `owner_kind` は `:row` / `:group` / `:frame` / `:total`、`owner` は行・章の Hash、枠は `Tree::Frame`、総単位は nil。`blocked: true`(指摘・問題が付いている)なら必ず false。
  - `#counted_categories(owner_kind, owner) -> Array<String>` — 持ち主が数える区分(行は自分の、章・枠は中の行の合併、総単位は `counts_toward_total` が false でない区分すべて)。Task 5 の書き戻しも同じ集合を使う。

- [ ] **Step 1: 失敗するテストを書く**

`test/services/curriculum_import/requirements_review/mirror_test.rb`。`RequirementsDraftFixtures` を include する。

```ruby
test '行と同じ単位・同じ区分の credit_sum は、持ち主と同じことを言っている'
  # 行 humanities(4単位, ['humanities']) と 規則 humanities(credit_sum, 4, ['humanities']) → true

test '単位が食い違う credit_sum は、同じことを言っていない'
  # 規則の required_credits を 6 にすると → false

test '区分が食い違う credit_sum は、同じことを言っていない'
  # 規則の categories を %w[humanities english] にすると → false

test 'credit_sum でない決まりは、同じことを言っていない'
  # one_of_paths / all_required / grouped_max / cap / exclude すべて false

test '章は、中の行の区分の合併と比べる'
  # 章 common(6単位) + 規則(credit_sum, 6, %w[humanities english]) → true
  # 規則の categories を ['humanities'] だけにすると → false

test '枠は、囲んでいる行の区分の合併と比べる'

test '総単位は、counts_toward_total が false でない区分すべてと比べる'
  # display.total_credits 14 + 規則 total(14, %w[humanities english required_core fusion]) → true
  # 'excluded' を足すと → false

test '指摘が付いている決まりは、同じことを言っていても false'
  # blocked: true → false

test '区分の順番が違っても、集合が同じなら true'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose exec -T web bin/rails test test/services/curriculum_import/requirements_review/mirror_test.rb`
Expected: FAIL（`Mirror` が無い）

- [ ] **Step 3: `Mirror` を実装する**

区分の比較は `Set` か `sort` で集合として。単位の比較は `BigDecimal` に寄せる(`2` と `2.0` を同じとする。`GraduationAssessment::Ledger.decimal` と同じ読み方)。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `docker compose exec -T web bin/rails test test/services/curriculum_import/requirements_review/mirror_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add app/services/curriculum_import/requirements_review/mirror.rb test/services/curriculum_import/requirements_review/mirror_test.rb
git commit -m "feat: 決まりが持ち主と同じことを言っているかの判定を足す"
```

---

## Task 4: 重複する箱を隠し、行の単位の欄を読むだけにする

仕様 §1・§1-2・§2-2。Task 3 の上。

**Files:**
- Modify: `app/services/curriculum_import/requirements_review.rb`, `app/helpers/requirements_review_helper.rb`, `app/views/curricula/_requirements_table.html.erb`, `_requirements_group.html.erb`, `_requirements_frame.html.erb`, `_requirements_row.html.erb`, `_requirements_row_more.html.erb`
- Test: `test/controllers/curricula_requirements_review_test.rb`

**Interfaces:**
- Consumes: `Mirror#duplicate?` / `#counted_categories`(Task 3)
- Produces:
  - `RequirementsReview#mirror` → `Mirror`
  - `RequirementsReview#hidden_rule(owner_kind, owner, shown_rules) -> Hash | nil` — `shown_rules` のうち持ち主と同じことを言っている1つ。画面はそれを箱として描かず、`…` に `label`/`detail` だけ出す。**`claim_rule_box?` は今までどおり呼ぶ**(隠しても「この画面で引き受けた」ことに変わりはない。呼ばないと、後ろの「どの行にも結びついていない決まり」が拾ってしまう)
  - `RequirementsReview#own_credits?(row) -> Boolean` — その行が、自分の `required_credits` の決まりを持っているか。false の行は単位の欄を入力にしない
  - `RequirementsReview#credits_held_by(row) -> String | nil` — 「上の枠『…』の22単位に含む」の文

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '行と同じことを言っている決まりの箱は、出さない' do
  show(draft)
  assert_select '#rule-humanities', false
  # 隠しても、その値は行に出ている
  assert_select '#row-humanities input[name=?][value=?]', 'display[groups][0][rows][0][required_credits]', '4'
end

test '行と食い違う決まりの箱は、出す' do
  # 規則 humanities の required_credits を 6 にした下書き
  assert_select '#rule-humanities'
end

test '隠した決まりの label と detail は、持ち主の … の中に出る' do
  assert_select '#row-humanities input[name=?]', 'rules[0][label]'
  assert_select '#row-humanities textarea[name=?], #row-humanities input[name=?]', 'rules[0][detail]'
end

test '自分の単位の決まりを持たない行は、単位を入力欄にしない' do
  # 行 required_core は、決まり core を章が先に取っている
  assert_select '#row-required_core input[name=?]', 'display[groups][1][rows][0][required_credits]', false
  assert_select '#row-required_core', text: /章「2. 必修」の4単位に含む/
end

test '隠した決まりも、どの行にも結びついていない決まりには落ちてこない' do
  assert_select '#requirements_rules #rule-humanities', false
end

test '指摘が付いている決まりの箱は、重複していても出す' do
  # Validation が humanities を指す下書きを作る
  assert_select '#rule-humanities'
end
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose exec -T web bin/rails test test/controllers/curricula_requirements_review_test.rb`
Expected: FAIL

- [ ] **Step 3: presenter に口を足す**

`RequirementsReview` に `mirror` / `hidden_rule` / `own_credits?` / `credits_held_by`。`hidden_rule` は `findings_for(:rule, id)` と `problems_for('rule', id)` を見て `blocked:` を渡す。

- [ ] **Step 4: `credit_slot` に読むだけの形を足す**

`RequirementsReviewHelper#credit_range` に `held_by:` を足し、与えられたら2つの欄の代わりにその文を出す(`rv-slot` の見た目)。

- [ ] **Step 5: 4つの view を直す**

各テンプレートで `shown_rules` から `hidden_rule` を除いてから描く。隠した決まりの `label`/`detail` は、`…`(`_requirements_row_more` と、章・枠・総単位の `details`)の中に `rule_param_key` の名前で出す。欄の名前は今までと同じなので、保存側の変更は要らない。

- [ ] **Step 6: テストが通ることを確かめる**

Run: `docker compose exec -T web bin/rails test test/controllers/curricula_requirements_review_test.rb`
Expected: PASS

- [ ] **Step 7: 全体のテスト**

Run: `docker compose exec -T web bin/rails test`
Expected: 0 failures。箱が出ることに依存していた既存テストは、隠れるのが正しいので期待を直す。`graduation_golden_2024.json` が変わっていないことを `git diff --stat` で確かめる。

- [ ] **Step 8: コミット**

```bash
git add app/services/curriculum_import/requirements_review.rb app/helpers/requirements_review_helper.rb app/views/curricula test/controllers/curricula_requirements_review_test.rb
git commit -m "feat: 行・章・枠と同じことを言っている決まりの箱を出さない"
```

---

## Task 5: 持ち主の欄が、隠れた決まりに書き戻す

仕様 §2。Task 3・4 の上。**ここが落とし穴を埋める本体。**

**Files:**
- Create: `app/services/curriculum_import/requirements_edit/mirror_writeback.rb`
- Modify: `app/services/curriculum_import/requirements_edit.rb:168-179`(`apply_sections`)
- Test: `test/services/curriculum_import/requirements_edit/mirror_writeback_test.rb`

**Interfaces:**
- Consumes: `Mirror`(Task 3)、`Bookkeeping#mark`(「人が確認した」印)
- Produces: `MirrorWriteback#mirror_writeback` — `apply_sections` の **`edit_display` と `add_new_row` のあと、`drop_orphaned_rules` の前**に呼ぶ private メソッド

**判定の前後関係:** `Mirror` は、保存する前の文書ではなく**保存しようとしている `@document`** の上で引く(行の区分を変えたあとの合併で比べる)。人がその保存で決まりの箱を直接直していたら(`@params[:rules]` にその id があるなら)、書き戻さない。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '行の必要単位を直すと、隠れている決まりの必要単位も直る' do
  save(draft, display: { groups: { '0' => { id: 'common', rows: { '0' => { id: 'humanities', required_credits: '6' } } } } })
  rule = reload_rule(draft, 'humanities')
  assert_equal 6, rule['required_credits']
  assert rule[CurriculumImport::DraftMerge::CONFIRMED]
end

test '行の区分を直すと、隠れている決まりの区分も直る'

test '行の区分を直すと、その行を含む章の隠れている決まりの区分も直る'
  # 行 humanities の区分を ['humanities','english'] にすると、章 common の決まりの合併も変わる

test '触らずに保存しても、文書は1バイトも変わらない' do
  before = draft.document.deep_dup
  save(draft, **everything_unchanged)
  assert_equal before, draft.reload.document
end

test '箱が出ている決まりには、書き戻さない' do
  # 規則 humanities の required_credits を 6 にした下書き(食い違うので箱が出る)
  # 行を 8 に直しても、規則は 6 のまま
end

test '同じ保存で決まりの箱も直していたら、そちらを優先する'

test '行を消した保存で、書き戻しが落ちない' do
  save(draft, display: { groups: { '0' => { id: 'common', rows: { '0' => { id: 'humanities', _destroy: '1' } } } } })
  assert_nil reload_rule(draft, 'humanities')   # drop_orphaned_rules が消す
end

test '行の区分を空にすると、隠れている決まりの区分も空になる' do
  # 空の categories を持つ credit_sum は何も数えない。黙って古い区分を数え続けさせない
end

test '総単位を直すと、総単位の決まりの必要単位も直る'
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose exec -T web bin/rails test test/services/curriculum_import/requirements_edit/mirror_writeback_test.rb`
Expected: FAIL

- [ ] **Step 3: `MirrorWriteback` を実装する**

画面と同じ順(総単位 → 章 → 枠 → 行)で持ち主をたどり、`Mirror#duplicate?` に当たる決まりへ `required_credits` と `categories` を書く。**値が今と違うときだけ書き、書いたら `mark` と `@edited += 1`。** 人が `@params[:rules]` でその id を送っていたら飛ばす。

`duplicate?` の判定は、書き戻す**前**の決まりの値で行う(書き戻したあとに引くと、常に一致して歯止めが効かない)。

- [ ] **Step 4: `apply_sections` に足す**

`add_new_row` と `drop_orphaned_rules` の間に `mirror_writeback`。

- [ ] **Step 5: テストが通ることを確かめる**

Run: `docker compose exec -T web bin/rails test test/services/curriculum_import/requirements_edit/mirror_writeback_test.rb test/services/curriculum_import/requirements_protection_test.rb`
Expected: PASS

- [ ] **Step 6: 全体のテストとコミット**

```bash
docker compose exec -T web bin/rails test
git diff --stat test/fixtures/files/graduation_golden_2024.json   # 空であること
git add app/services/curriculum_import/requirements_edit test/services/curriculum_import/requirements_edit
git commit -m "feat: 行・章・枠の必要単位と区分を、隠れている決まりにも書く"
```

---

## Task 6: 経路を、役割キーではなく科目で選ぶ

仕様 §3-1。いちばん大きい。

**Files:**
- Create: `app/helpers/requirement_course_chips_helper.rb`
- Modify: `app/views/curricula/_requirements_rule_paths.html.erb`, `app/services/curriculum_import/requirements_review.rb`, `app/services/curriculum_import/requirements_edit/nested_coercion.rb`, `app/services/curriculum_import/draft_merge.rb:209-216`
- Test: `test/services/curriculum_import/requirements_edit/paths_test.rb`(新規), `test/services/curriculum_import/courses_protection_test.rb`, `test/controllers/curricula_requirements_review_test.rb`

**Interfaces:**
- Consumes: `Validation::Input#courses`、`RequirementsReview#category_keys` / `#category_label`
- Produces:
  - `RequirementsReview#path_courses(path) -> Array<[role, label]>` — 経路が名指しする役割を、科目の「番号 名前」にして返す。科目が無い役割は `"<role>(科目表にありません)"`
  - `RequirementsReview#course_options(category) -> Array<[label, key]>` — 区分で絞った科目の選択肢
  - `RequirementCourseChipsHelper#course_chips(name, path, review)` — チップ＋「＋ 科目を足す」(区分の選択 → 科目の選択の2段)
  - 欄の名前は今までどおり `rules[N][paths][I][roles][]`。**送る値が役割キーから科目の `key` に変わる**(保存側が役割に直す)

- [ ] **Step 1: 失敗するテストを書く**

保存側(`test/services/curriculum_import/requirements_edit/paths_test.rb`):

```ruby
test '役割を持つ科目を選ぶと、その役割が経路に入る' do
  # 科目 人101 は roles: ['role_a']。key 'course_人101' を送ると paths は [['role_a']]
end

test '役割を持たない科目を選ぶと、その科目の key が役割になり、科目にも足される' do
  # 人103(roles なし)を送る → paths に 'course_人103'、courses の 人103 の roles に 'course_人103'
end

test '役割を足した科目に、人が確認した印は付けない'

test '経路から科目を外すと、どの経路も名指ししていない役割は科目からも消える'

test 'ほかの決まりがまだ名指ししている役割は、科目から消さない'

test '科目表に無い key が送られたら、保存せず問題にする'
  # Review Focus 3

test '同じ科目を2つの経路に選んだら、保存せず問題にする'
  # Review Focus 4。OneOfPaths#mixed? が全員を要確認にするので、画面で止める
end
```

読み直しの保護(`test/services/curriculum_import/courses_protection_test.rb`):

```ruby
test '科目表を読み直しても、要件表の画面が足した役割は消えない'
```

画面(`curricula_requirements_review_test.rb`):

```ruby
test '経路は、役割キーではなく科目の番号と名前で出る' do
  assert_select '#rule-path_rule', text: /人101 哲学/
  assert_select '#rule-path_rule', text: /role_a/, count: 0
end

test '経路に、ほかの決まりの役割を並べない' do
  # いまは便覧じゅうの役割を全部チェックで並べている
  assert_select '#rule-path_rule input[type=checkbox]', count: 0
end
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose exec -T web bin/rails test test/services/curriculum_import/requirements_edit/paths_test.rb test/services/curriculum_import/courses_protection_test.rb`
Expected: FAIL

- [ ] **Step 3: `DraftMerge#course_entry` が役割を消さないようにする**

既存の科目の `roles` と、読み取りが返した `roles` を合わせる(`|`)。既存の科目が見つからないときは今までどおり。

- [ ] **Step 4: 保存側(`nested_coercion.rb`)で、科目の key を役割に直す**

送られた値が科目の `key` なら役割に直し、必要なら `courses[].roles` に足す。すでに役割キーなら今までどおり通す(保存できなかった送信を戻したときのため)。外した役割の掃除も、ここで。

- [ ] **Step 5: presenter と view を直す**

`path_courses` / `course_options` を足し、`_requirements_rule_paths.html.erb` の `role_checks` を `course_chips` に替える。「経路1(すべて修得して1つの経路)」は「次のどれか1組を、すべて修得」+ 組ごとの `・` に。経路が1つだけなら「次の科目をすべて修得」。

`RequirementsReviewHelper#role_checks` は使われなくなるので消す(テストも)。

- [ ] **Step 6: テストが通ることを確かめる**

Run: `docker compose exec -T web bin/rails test test/services/curriculum_import test/controllers/curricula_requirements_review_test.rb`
Expected: PASS

- [ ] **Step 7: 全体のテストとコミット**

```bash
docker compose exec -T web bin/rails test
git diff --stat test/fixtures/files/graduation_golden_2024.json   # 空であること
git add app/helpers/requirement_course_chips_helper.rb app/views/curricula/_requirements_rule_paths.html.erb app/services test/
git commit -m "feat: 経路を役割キーではなく科目で選べるようにする"
```

---

## Task 7: グループの分け方を選択肢にする

仕様 §3-3。

**Files:**
- Modify: `app/helpers/requirements_review_helper.rb`, `app/services/curriculum_import/requirements_edit/coercion.rb`, `app/services/curriculum_import/requirements_review.rb`, `app/helpers/rule_sentence_helper.rb:18`
- Test: `test/helpers/requirements_review_helper_test.rb`, `test/services/curriculum_import/requirements_edit/rule_editing_test.rb`

**Interfaces:**
- Produces: `RequirementsReview#group_by_options(rule) -> Array<[label, value]>` — 既定の2つ(`['提供コース（科目番号の先頭）', 'number_prefix']`, `['言語', 'field:language']`)に、いまの値が2つに無ければ `["いまの設定: #{value}", value]` を足す

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'グループの分け方は、提供コースと言語の選択肢で出る'
test '2択に無い値は、いまの設定として選択肢に残る'
  # group_by: 'field:credits' → options に ['いまの設定: field:credits', 'field:credits']
test '選び直さずに保存しても、group_by は変わらない'
test 'group_by を選び直したときだけ、group_label を書く'
  # number_prefix を選ぶ → group_label '提供コース'
  # group_by を触らない保存では、AI が書いた group_label('開講コース'等)を上書きしない
test '学生の画面は、同一の提供コースからと出る'
  # RuleSentenceHelper::GROUP_BY_NAMES
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `docker compose exec -T web bin/rails test test/helpers/requirements_review_helper_test.rb test/helpers/requirements_helper_test.rb`
Expected: FAIL

- [ ] **Step 3: 実装する**

`rule_field_control` に `field == 'group_by'` の分岐(`group_by_select`)。`group_label` の欄は画面から消し、`Coercion` 側で `group_by` が変わったときだけ書く。`GROUP_BY_NAMES` を `{ 'number_prefix' => '提供コース' }` に。

- [ ] **Step 4〜5: テストを通してコミット**

```bash
docker compose exec -T web bin/rails test
git commit -am "feat: グループの分け方を選択肢にし、呼び名を自動で決める"
```

---

## Task 8: 残る決まりを、日本語の1行で出す

仕様 §3-2・§3-4・§3-5・§3-6。画面だけ。

**Files:**
- Create: `app/views/curricula/_requirements_rule_line.html.erb`
- Modify: `app/views/curricula/_requirements_rule.html.erb`, `_requirements_rule_condition.html.erb`, `_requirements_rule_nested.html.erb`, `app/helpers/requirements_review_helper.rb`
- Test: `test/controllers/curricula_requirements_review_test.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '決まりの箱に、型の名前を出さない' do
  assert_select '#rule-fusion_provider', text: /同じ提供元・言語から/, count: 0
end

test 'credit_sum は「◯◯ から ◯単位以上」と出る'
test 'grouped_max は「◯◯ のうち、同じ 提供コース から ◯単位以上」と出る'
test 'all_required は「科目表で必修になっている科目を、すべて修得」と、科目表の実数を出す' do
  assert_select '#rule-core', text: /科目表の必修は 2 科目/
end
test 'any_of は「次のどちらかを満たす」と出る'
test '入れ子の種類に、credit_sum のような内部の名前を出さない'
```

- [ ] **Step 2〜5: 実装・テスト・コミット**

`_requirements_rule_line.html.erb` が、型ごとに文の骨を組む。既存の `credit_range` と `category_chips` をそのまま差し込む。`rule_type_name` を使うのは「決まりを足す」の選択肢だけに絞る。`all_required` の実数は `review.courses.count { |c| c['required'] }`。

```bash
docker compose exec -T web bin/rails test
git commit -am "feat: 残る決まりを、型の名前なしの日本語で出す"
```

---

## Task 9: 出典を1箇所にし、文字を大きくする

仕様 §4・§5。

**Files:**
- Modify: `app/views/curricula/_requirements_review.html.erb`, `_requirements_rule.html.erb:34`, `app/services/curriculum_import/requirements_review.rb`, `app/assets/tailwind/application.css:16-47,143-166`
- Test: `test/controllers/curricula_requirements_review_test.rb`

**Interfaces:**
- Produces: `RequirementsReview#source_pages -> Array<String>` — 決まりの `source_page` のユニーク。空は除く

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '出典は、節の見出しの下に1箇所だけ出る' do
  show(draft)
  assert_select '#requirements_review', text: /出典: PDF3ページ/
  assert_select '#rule-core', text: /出典/, count: 0
end

test '出典が4種類以上あるときは、決まりごとにも出す' do
  # 4つの決まりに別々の source_page を持たせた下書き
  assert_select '#rule-core', text: /出典/
end

test '出典が無い下書きでは、出典の行を出さない'
```

- [ ] **Step 2〜5: 実装・テスト・コミット**

`.rv-field` `.rv-chip-text` `.rv-slot` `.rv-more` `.cr-chip` `.cr-btn` の `text-xs` を `text-sm` に。節の説明文を2文に削る。

```bash
docker compose exec -T web bin/rails test
git commit -am "feat: 出典を節に1箇所にし、本文の文字を text-sm に上げる"
```

---

## Task 10: 拾った小さな傷

仕様 §8。

**Files:**
- Modify: `app/views/curricula/_requirements_categories.html.erb:15`, `_requirements_excludes.html.erb`, `app/helpers/requirements_chips_helper.rb:12`, `app/helpers/requirements_review_helper.rb`
- Test: `test/controllers/curricula_requirements_review_test.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test '区分の一覧に、内部のキーを出さない' do
  assert_select '#category-humanities', text: /\(humanities\)/, count: 0
  assert_select '#category-humanities', text: /人文系/
end

test '決まりの区分も、行と同じ「対象：」と呼ぶ' do
  assert_select '#requirements_table', text: /数える区分/, count: 0
end

test '算入の上限の箱に、同じ言葉を二度出さない' do
  # 「算入の上限 算入の上限」
end
```

算入しない科目のラベルの重なりは、`_requirements_excludes.html.erb` のグリッドを `sm:grid-cols-2` の中で `rule_field_input` が縦に積むように直す(目で確かめる)。

- [ ] **Step 2〜5: 実装・テスト・コミット**

```bash
docker compose exec -T web bin/rails test
git commit -am "fix: 区分キー・ラベルの重なり・言葉の不統一を直す"
```

---

## Task 11: 画面で確かめる

**Files:** なし(確認のみ)

- [ ] **Step 1: 全体のテスト**

Run: `docker compose exec -T web bin/rails test`
Expected: 0 failures

- [ ] **Step 2: ゴールデンが動いていないことを確かめる**

Run: `git diff --stat test/fixtures/files/graduation_golden_2024.json config/curricula/`
Expected: 出力なし

- [ ] **Step 3: RuboCop**

Run: `docker compose exec -T web bin/rubocop`
Expected: no offenses

- [ ] **Step 4: 実データの下書きを開いて測る**

`/curricula/13`(2024年度・484科目・27決まり)を 1440×1000 で開き、着手前の実測と比べる。

| | 着手前 | 目安 |
|---|---|---|
| 画面全体 | 39,390px | 1万px未満 |
| 要件表の確認 | 10,547px | 7千px未満 |
| 科目表の確認 | 27,937px | 2千px未満(節が畳まれている) |
| 決まりの箱 | 27個 | 15個 |
| 「出典」の行 | 27本 | 1本 |

- [ ] **Step 5: 判定が変わっていないことを、画面で確かめる**

デモ学生の `/requirements` とダッシュボードを、着手前後で見比べる。同じ数字・同じ判定であること。

- [ ] **Step 6: 仕上げのコミット**

```bash
git commit --allow-empty -m "chore: 編集画面の簡素化を確認する"
```

---

## 自己点検

**仕様の網羅:** §1→Task 3・4 / §1-2→Task 4 / §2→Task 5 / §2-2→Task 4(Step 5) / §3-1→Task 6 / §3-2→Task 8 / §3-3→Task 7 / §3-4→Task 8 / §3-5→Task 8 / §3-6→Task 8 / §4→Task 9 / §5→Task 9 / §6→Task 2 / §7→Task 1 / §8→Task 10・Task 7(`GROUP_BY_NAMES`)。漏れなし。

**Review Focus の割り当て:** 1→Task 5「行を消した保存で、書き戻しが落ちない」 / 2→Task 5「行の区分を空にすると」 / 3→Task 6「科目表に無い key」 / 4→Task 6「同じ科目を2つの経路に」 / 5→Task 1「画像が無いページ」。すべて、そのコードを持つタスクのテストにある。

**名前の一貫性:** `Mirror#duplicate?` / `#counted_categories` は Task 3 で定義し、Task 4(presenter)と Task 5(書き戻し)が同じ名前で引く。`RequirementsReview#hidden_rule` は Task 4 で定義し、Task 8 の view が同じ名前で引く。経路の欄の名前 `rules[N][paths][I][roles][]` は Task 6 の画面と保存で同じ。

**依存の向き:** 1・2 は独立。3 → 4 → 5 が一本。6・7・8・9・10 は 4 のあと(view を触るため)。11 は最後。
