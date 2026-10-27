# 取り込み確認画面のPDFペインと行追加 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 取り込みの確認画面に、自分でスクロールするPDFペインと、読み取れなかった科目を行として足す手段を加える。

**Architecture:** 取り込み時に `gs` でページ画像を作って `storage/timetable_uploads/<id>/` に置き、`send_file` で返す。画面は `thead` の先頭行にペインを置き、Stimulusで倍率・ページ送り・開閉を扱う。行の追加・削除は新しいアクションを作らず、既存の `update_rows` の送信（`operation`）に乗せて、入力中の値を保存してから行を増やす・減らす。

**Tech Stack:** Rails 8 / Hotwire(Turbo morph + Stimulus) / Tailwind / PostgreSQL / Ghostscript / Minitest

**Spec:** `docs/superpowers/specs/2026-10-20-timetable-upload-pdf-pane-design.md`

## Global Constraints

- 画像は `-sDEVICE=png16m -r150`、`storage/timetable_uploads/<upload_id>/p<n>.png`（`n` は1始まり）。
- 画像化に失敗しても取り込みは成立する（ペインを出さないだけ）。
- 画像の配信・行の操作は `LocalAccessOnly` の下（ローカル以外は404）。
- 行の追加・削除は `rows-form` の送信ボタンで行う。別経路にして入力中の値を捨てない。
- コメント・画面の文言は日本語。既存ファイルの書き方に合わせる。
- テストで `gs` は動かさない。画像化は `TimetableImport::PageImages.render` をスタブする。

## Review Focus

- ページ番号に数字でない値や範囲外（`0`、`99`、`../../etc/passwd`）が来たとき、404で返ること。→ Task 2
- 画像が1枚も無い取り込みを開いたとき、ペインを出さずに画面が普通に出ること。→ Task 3
- `after_row_id` に他の取り込みの行IDや存在しないIDが来たとき、その取り込みの末尾に足すだけで壊れないこと。→ Task 4
- `destroy_row_id` に他の取り込みの行IDが来たとき、その行を消さないこと。→ Task 5
- 行を足す・消すときに、同じ送信に乗っている入力中の値が保存されること。→ Task 4 / Task 5

---

### Task 1: ページ画像を作って保管する

**Files:**
- Create: `lib/timetable_import/page_images.rb`
- Modify: `app/models/timetable_upload.rb`（`build_from_pdf` に画像化を足し、置き場所と後始末を持たせる）
- Test: `test/models/timetable_upload_test.rb`（新規）

**Interfaces:**
- Produces: `TimetableImport::PageImages.render(pdf_path, dir)` → 作ったページ数(Integer)。`dir` を作り直してから `p1.png` 以降を書く。`gs` が無い・失敗したときは `TimetableImport::PageImages::Error` を投げる。
- Produces: `TimetableUpload#images_dir` → `Pathname`、`TimetableUpload#page_image_path(page)` → `Pathname` または `nil`、`TimetableUpload#page_count` → Integer。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'build_from_pdf renders page images into the upload folder' do
  TimetableImport::PageImages.stub(:render, ->(_pdf, dir) { FileUtils.mkdir_p(dir); File.write(File.join(dir, 'p1.png'), 'png'); 1 }) do
    upload = TimetableUpload.build_from_pdf('dummy.pdf', semester: '前期', filename: 'a.pdf')
    assert_equal 1, upload.page_count
    assert_equal 'png', File.read(upload.page_image_path(1))
    assert_nil upload.page_image_path(2)
  end
end

test 'an upload still works when the pages cannot be rendered' do
  TimetableImport::PageImages.stub(:render, ->(_pdf, _dir) { raise TimetableImport::PageImages::Error, 'gsが無い' }) do
    upload = TimetableUpload.build_from_pdf('dummy.pdf', semester: '前期', filename: 'a.pdf')
    assert_equal 1, upload.rows.size
    assert_equal 0, upload.page_count
  end
end

test 'destroying an upload removes its page images' do
  # 画像を1枚置いた取り込みを destroy! して、images_dir が消えていること
end
```

`PdfParser.extract_xml` / `PdfParser#rows` は `test/controllers/course_registrations_test.rb` と同じ形の合成XMLでスタブする。

- [ ] **Step 2: テストが落ちることを確認する**

Run: `docker compose exec -T web bin/rails test test/models/timetable_upload_test.rb`
Expected: FAIL（`TimetableImport::PageImages` が無い）

- [ ] **Step 3: `TimetableImport::PageImages.render(pdf_path, dir)` を実装する**

`Open3.capture2` で `gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=png16m -r150 -sOutputFile=<dir>/p%d.png <pdf>` を呼び、できた `p*.png` の数を返す。`Errno::ENOENT` と失敗ステータスは `Error` にする。`PdfParser.extract_xml` のエラーの出し方に合わせる。

- [ ] **Step 4: `TimetableUpload` に置き場所・枚数・後始末を足す**

`images_dir` は `Rails.root.join('storage', 'timetable_uploads', id.to_s)`。`build_from_pdf` のトランザクションの外（行を作ったあと）で `PageImages.render` を呼び、`PageImages::Error` は握りつぶす。`after_destroy` で `FileUtils.rm_rf(images_dir)`。

- [ ] **Step 5: テストが通ることを確認する**

Run: `docker compose exec -T web bin/rails test test/models/timetable_upload_test.rb`
Expected: PASS

- [ ] **Step 6: コミット**

```bash
git add lib/timetable_import/page_images.rb app/models/timetable_upload.rb test/models/timetable_upload_test.rb
git commit -m "feat: 取り込んだPDFのページ画像を作って保管する"
```

---

### Task 2: 画像を返すアクション

**Files:**
- Modify: `config/routes.rb`（`timetable_uploads` の member に `get 'page_image/:page'`、`as: :page_image`）
- Modify: `app/controllers/timetable_uploads_controller.rb`
- Test: `test/controllers/course_registrations_test.rb`

**Interfaces:**
- Consumes: `TimetableUpload#page_image_path(page)`
- Produces: `page_image_timetable_upload_path(upload, page)` → PNGを `inline` で返す。無ければ404。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'page images are served to local access only, and missing pages are not found' do
  # 画像を1枚置いた取り込みで
  get page_image_timetable_upload_path(upload, 1), env: ENV_LOCAL
  assert_response :success
  assert_equal 'image/png', response.media_type

  get page_image_timetable_upload_path(upload, 2), env: ENV_LOCAL
  assert_response :not_found

  get page_image_timetable_upload_path(upload, '../../config/database'), env: ENV_LOCAL
  assert_response :not_found

  get page_image_timetable_upload_path(upload, 1) # ローカル以外
  assert_response :not_found
end
```

- [ ] **Step 2: テストが落ちることを確認する**

Run: `docker compose exec -T web bin/rails test test/controllers/course_registrations_test.rb`
Expected: FAIL（ルーティングが無い）

- [ ] **Step 3: ルートと `page_image` アクションを足す**

`params[:page]` は `Integer(..., exception: false)` で数字だけ受ける。`page_image_path` が `nil` なら `head :not_found`。あるなら `send_file path, type: 'image/png', disposition: 'inline'`。

- [ ] **Step 4: テストが通ることを確認する**

Run: `docker compose exec -T web bin/rails test test/controllers/course_registrations_test.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git commit -am "feat: 取り込みのページ画像を返すアクションを足す"
```

---

### Task 3: PDFペインを画面に出す

**Files:**
- Create: `app/views/timetable_uploads/_pdf_pane.html.erb`
- Create: `app/javascript/controllers/pdf_pane_controller.js`
- Modify: `app/views/timetable_uploads/show.html.erb`（`thead` の先頭にペインの行を入れる）
- Test: `test/controllers/course_registrations_test.rb`

**Interfaces:**
- Consumes: `page_image_timetable_upload_path`、`TimetableUpload#page_count`
- Produces: `thead` の `tr#pdf-pane-row`（`data-controller="pdf-pane"`）。中に `data-pdf-pane-target="scroll"` のスクロール枠、`page` のimg複数、`zoom`/`zoomValue` の入力、`headRow`（見出しの行）を貼り付ける高さの計算対象。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'the pdf pane shows every page, and is left out when there are no images' do
  # 画像を2枚置いた取り込み
  get timetable_upload_path(upload), env: ENV_LOCAL
  assert_select 'tr#pdf-pane-row[data-controller=pdf-pane]'
  assert_select "img[src='#{page_image_timetable_upload_path(upload, 1)}']"
  assert_select "img[src='#{page_image_timetable_upload_path(upload, 2)}']"
  assert_select 'button', text: '幅に合わせる'

  # 画像の無い取り込み
  get timetable_upload_path(other), env: ENV_LOCAL
  assert_select 'tr#pdf-pane-row', 0
end
```

- [ ] **Step 2: テストが落ちることを確認する**

Run: `docker compose exec -T web bin/rails test test/controllers/course_registrations_test.rb`
Expected: FAIL

- [ ] **Step 3: `_pdf_pane.html.erb` を書く**

モック（`mock-scroll-and-add.html` の `#pdf-pane-row`）と同じ構成・同じ文言。`th` は `colspan` 10。
スクロール枠は `style="height:300px;resize:vertical"` と `overflow-auto`。画像は `width` をJSが決めるので、
`display:block;margin:0 auto` だけ付ける。

- [ ] **Step 4: `pdf_pane_controller.js` を書く**

targets: `scroll` `page` `zoom` `zoomValue` `pane` `hidden`。
- `fitWidth()`: 倍率 = スクロール枠の幅 ÷ ページの実寸幅（`naturalWidth`。読み込み前なら `load` を待つ）。接続時にこれを呼ぶ。
- `applyZoom(keepCenter)`: 各ページの `width` を 実寸×倍率 にし、スライダーと数値を合わせ、横は中央（`keepCenter` なら前の中央、初回は真ん中）。
- `setZoom(next)`: 0.25〜2.5 に収めて `applyZoom(true)`。`zoomIn` `zoomOut` `slide` `type` から呼ぶ。
- `jump(event)`: 押されたページの `offsetTop` までスクロールする。
- `toggle()` / `show()`: ペインを隠す・出す。どちらでも `stickHeader()` を呼ぶ。
- `stickHeader()`: 見出しの行の `top` を、今出ている上の行の高さにする。`ResizeObserver` でも呼ぶ。
- `turbo:morph` で作り直されても困らないよう、状態はDOM（倍率の入力値）だけに持つ。

- [ ] **Step 5: `show.html.erb` から `page_count.positive?` のときだけ描く**

- [ ] **Step 6: テストが通ることを確認する**

Run: `docker compose exec -T web bin/rails test test/controllers/course_registrations_test.rb`
Expected: PASS

- [ ] **Step 7: 画面で確かめる**

ローカルの取り込みを開き、ペインが幅に合わせて開くこと、倍率を変えても中央が保たれること、
ページ送り・隠す・高さ変更が効くこと、表をスクロールしてもペインと見出しが残ることを見る。

- [ ] **Step 8: コミット**

```bash
git commit -am "feat: 取り込みの確認画面にPDFペインを出す"
```

---

### Task 4: 読み取れなかった科目の行を足す

**Files:**
- Create: `db/migrate/<timestamp>_add_added_by_hand_to_timetable_upload_rows.rb`
- Modify: `app/models/timetable_upload.rb`（`add_row_after`）
- Modify: `app/controllers/timetable_uploads_controller.rb`（`update_rows` の `operation`）
- Modify: `app/views/timetable_uploads/show.html.erb`（下の固定バーの追加ボタンと行き先の表示、hiddenの `after_row_id`）
- Create: `app/javascript/controllers/add_row_controller.js`（最後に触った行を覚え、行き先を出す）
- Test: `test/controllers/course_registrations_test.rb`

**Interfaces:**
- Produces: `TimetableUpload#add_row_after(row_id)` → 作った `TimetableUploadRow`。`row_id` がこの取り込みの行でなければ末尾に足す。後ろの行の `position` を1つずつずらす。`added_by_hand: true`。
- Produces: 送信パラメータ `operation=add_row` と `after_row_id`。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'adding a row puts an empty row right after the chosen one and keeps the edits' do
  # 3行の取り込みで、1行目に値を打ちながら operation=add_row / after_row_id=1行目のID を送る
  assert_difference 'upload.rows.count', 1 do
    update_rows(upload, changes: { first => { 'name' => '直した名前' } }, operation: 'add_row', after_row_id: first.id)
  end
  assert_equal '直した名前', first.reload.name
  added = upload.rows.reload[1]
  assert_predicate added, :added_by_hand
  assert_equal '', added.name.to_s
  assert_equal [0, 1, 2, 3], upload.rows.reload.map(&:position)
end

test 'adding a row without a target, or with a row from another upload, appends it to the end' do
  # after_row_id が空 / 他の取り込みの行ID → 末尾に入る
end
```

- [ ] **Step 2: テストが落ちることを確認する**

Run: `docker compose exec -T web bin/rails test test/controllers/course_registrations_test.rb`
Expected: FAIL

- [ ] **Step 3: マイグレーションを足して流す**

`add_column :timetable_upload_rows, :added_by_hand, :boolean, default: false, null: false`

- [ ] **Step 4: `TimetableUpload#add_row_after(row_id)` を実装する**

- [ ] **Step 5: `update_rows` で `operation == 'add_row'` のときに呼ぶ**

編集の保存（`apply_edits`）のあとに足す。知らせ（トースト）は出さない。

- [ ] **Step 6: 画面に追加ボタンを足す**

下の固定バーの先頭に `＋ 科目を追加`（`rows-form` の送信ボタン、`name: 'operation', value: 'add_row'`）と、
行き先を出す `span`、`hidden_field_tag :after_row_id`。`add_row_controller.js` が、表の `focusin`/`click` で
最後に触った行を覚え、hiddenと行き先の文言（`<講義コード> の下に` / `表のいちばん下に`）を書き換える。

- [ ] **Step 7: テストが通ることを確認する**

Run: `docker compose exec -T web bin/rails test test/controllers/course_registrations_test.rb`
Expected: PASS

- [ ] **Step 8: コミット**

```bash
git commit -am "feat: 読み取れなかった科目の行を、選んだ行の下に足せるようにする"
```

---

### Task 5: 手で足した行の見た目と削除

**Files:**
- Modify: `app/views/timetable_uploads/show.html.erb`（足した行の色・印・削除ボタン）
- Modify: `app/controllers/timetable_uploads_controller.rb`（`destroy_row_id`）
- Test: `test/controllers/course_registrations_test.rb`

**Interfaces:**
- Consumes: `TimetableUploadRow#added_by_hand`
- Produces: 送信パラメータ `destroy_row_id=<行ID>`（`rows-form` の送信ボタン）。

- [ ] **Step 1: 失敗するテストを書く**

```ruby
test 'a hand-added row is marked, can be deleted, and keeps the edits in the same submit' do
  # added_by_hand の行がある状態で
  get timetable_upload_path(upload), env: ENV_LOCAL
  assert_select "tbody#row-#{added.id}", text: /手で追加した行/
  assert_select "button[name=destroy_row_id][value='#{added.id}']"

  assert_difference 'upload.rows.count', -1 do
    update_rows(upload, changes: { first => { 'name' => '直した名前' } }, destroy_row_id: added.id)
  end
  assert_equal '直した名前', first.reload.name
end

test 'a row id from another upload is not deleted' do
  # 他の取り込みの行IDを送っても消えないこと
end
```

- [ ] **Step 2: テストが落ちることを確認する**

Run: `docker compose exec -T web bin/rails test test/controllers/course_registrations_test.rb`
Expected: FAIL

- [ ] **Step 3: `update_rows` で `destroy_row_id` の行を消す**

`@upload.rows.find_by(id: params[:destroy_row_id])&.destroy!`。編集の保存のあとに消す。

- [ ] **Step 4: 画面に印と削除ボタンを出す**

`row.added_by_hand` のとき、行の色を `bg-amber-50` にし、行の下に `手で追加した行 ― PDFを見ながら入力してください` と
`この行を削除`（送信ボタン、`name: 'destroy_row_id', value: row.id`）を出す。モックと同じ文言。

- [ ] **Step 5: テストが通ることを確認する**

Run: `docker compose exec -T web bin/rails test test/controllers/course_registrations_test.rb`
Expected: PASS

- [ ] **Step 6: 画面で確かめる**

行を足す→入力する→確認済みにする→保存まで通ること、足した行を消せることを見る。

- [ ] **Step 7: 全体のテストとRuboCop**

Run: `docker compose exec -T web bin/rails test` / `docker compose exec -T web bundle exec rubocop app lib test`
Expected: どちらも緑

- [ ] **Step 8: コミット**

```bash
git commit -am "feat: 手で足した行を見分けられるようにし、消せるようにする"
```
