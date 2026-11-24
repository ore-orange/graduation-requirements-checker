# courses と course_offerings の統合（#53）設計

## 目的

授業時間配当表のPDFから取り込んだ1行を、DBの1行として扱えるようにする。

いまは1件の講義が、科目マスタ `courses` と学期ごとの開講情報 `course_offerings` の
2行に分かれている。そのため、

- 講義を1件表示するだけでも2テーブルをたどる必要がある
- 取り込みのたびに「既存の科目に紐づけるか、新しい科目として登録するか」を人に選ばせており、
  確認画面にその欄があり、Importerにもその分岐がある

1テーブルにまとめると、取り込んだ行がそのまま1行になり、取り込み処理から科目の引き当てごと
消せる。講義の同一性は、年度・学期・講義コードの一意性だけで決まる。

## ゴール

- `course_offerings` を廃止し、講義1件＝1行のテーブルにする
- 取り込み（`TimetableImport::Importer`）の保存先を統合テーブルにし、科目の引き当てをなくす
- 履修履歴（`student_courses`）・履修計画（`planned_courses`）・卒業判定を壊さない
- `docs/database-design.md` のER図と表を統合後の形に直す

## 非ゴール

- 取り込んだ講義に `curriculum_key` を付けて便覧の科目と突き合わせること（別issue）
- 講義の一覧・絞り込みの見せ方を変えること（#48 で決めた形を保つ）
- 再履修・同等科目の判定ロジックを変えること
- 履修履歴の取り込み（成績データ）に手を入れること

## アンチゴール（これが起きたら失敗）

- 卒業判定の結果が、同じ履修データで変わる
- 履修計画に入っている科目が画面から消える、または参照が切れる
- 保存済みの講義が移行で消える
- 「便覧の科目」と「開講1件」が、どちらとも読める形で1テーブルに混ざり、
  列の意味がコードを読まないとわからなくなる

## 制約

- Rails 8.1 / PostgreSQL 17。migrationで移行する（手作業のSQLを前提にしない）
- 本番DBに取り込み済みの講義がある可能性があるため、データを消さずに移す
- `student_courses` / `planned_courses` は `course_id` で `courses` を参照しており、
  `timetable_upload_rows` も `courses` を参照している
- 卒業判定は `curriculum_key` で科目を突き合わせる。`courses.curriculum_key` は
  値があるとき一意（部分unique index）
- 便覧（カリキュラムJSON）由来の科目は、年度・学期・講義コードを持たない

## 検討した案

### 案A：`courses` に `course_offerings` の列を移して1本化（採用）

テーブル名は `courses` のまま。`course_offerings` の列（年度・学期・講義コード・必修選択・
受講年次・曜日・時限・開講区分・開講学科）を `courses` に移し、`course_offerings` を削除する。
便覧由来の科目は、それらの列が空の行として同じテーブルに入る。
`student_courses` / `planned_courses` / `timetable_upload_rows` の参照先は `courses` のまま。

- 利点：履修・判定・画面のほとんどに手が入らない。外部キー列名（`course_id`）も変わらない。
  取り込みから科目の引き当てを消すという、この変更の本体に集中できる。
- 欠点：1テーブルに「便覧の科目（開講列が空）」と「開講1件」の2種類の行が同居する。
  この区別を、check制約と `scope` で読めるようにしておく必要がある。

### 案B：統合テーブルを開講講義専用にし、履修・計画は `curriculum_key` を直接持つ

統合テーブルを `lectures` のような新しい名前にし、`courses` を廃止。
`student_courses` / `planned_courses` から `course_id` を外し、`curriculum_key` を持たせる。

- 利点：「1件の講義＝1行」が例外なく成り立つ。判定は `curriculum_key` で素直に重複排除できる。
- 欠点：履修2テーブルの列の入れ替えとデータ移行が必要で、外部キーが外れる。画面・ヘルパー・
  サービスが `record.course.curriculum_key` でたどっている箇所すべてに影響する。
  いま困っているのは取り込み側なので、履修側を大きく壊すのは割に合わない。

### 案C：2テーブルのまま、画面と取り込みだけ整理する

- 却下。issueの狙い（1件の講義を1行で扱う）を満たさない。取り込みの科目引き当ても残る。

**採用：案A。** 本人の選択。

## 決めたこと

### 統合後のテーブル

テーブル名は `courses`。列は次のとおり（★が `course_offerings` から移すもの）。

| 列 | 型 | NULL | 内容 |
| --- | --- | --- | --- |
| id | bigint | × | PK |
| course_number | string | ○ | 科目番号 |
| name | string | × | 科目名 |
| credits | integer | ○ | 単位 |
| curriculum_key | string | ○ | 便覧の科目キー。値があるとき一意 |
| ★ year | integer | ○ | 開講年度（2026年度の後期も2026） |
| ★ semester | string | ○ | 前期・後期 |
| ★ lecture_code | string | ○ | 講義コード |
| ★ requirement_type | string | ○ | 必修・選択 |
| ★ grade_years | integer[] | × | 受講年次。既定 `[]` |
| ★ weekday | string | ○ | 曜日 |
| ★ periods | integer[] | × | 時限。既定 `[]` |
| ★ term_type | string | ○ | 開講区分（半年・1Q・2Q・通年・集中） |
| ★ department_id | bigint | ○ | 開講学科。学部は `departments.faculty_id` からたどる |
| created_at / updated_at | datetime | × | |

### 制約・index

- unique index `(year, semester, lecture_code) WHERE lecture_code IS NOT NULL`
  — 講義の同一性はこれだけで決まる。年度が違えば同じ講義コードを登録できる。
  部分indexにするのは、便覧由来の行（3列すべてNULL）を対象から外して意図を読めるようにするため。
- `curriculum_key` の部分unique index（既存）はそのまま残す。取り込んだ行は `curriculum_key` を
  持たないので衝突しない。**これが「同じ科目を重複して数えない」の担保**（後述）。
- index `department_id`、index `course_number`（既存）はそのまま。
- check制約
  - `courses_offering_pair`：`(lecture_code IS NULL AND semester IS NULL) OR (lecture_code IS NOT NULL AND semester IS NOT NULL)`
    — 「開講1件の行」と「便覧の科目の行」の2種類しかないことをDBで示す。
  - `courses_semester`：`semester IS NULL OR semester IN ('前期','後期')`
  - `courses_requirement_type`：`requirement_type IS NULL OR requirement_type IN ('必修','選択')`
  - `courses_year_range`：`year IS NULL OR (year >= 1 AND year <= 9999)`
  - `courses_nonnegative_credits`（既存）はそのまま。
- `year` / `department_id` をNULL可にするのは、便覧由来の行のため。取り込み画面では年度・学科を
  必須で選ばせるので、PDFから入った行が空になることはない。
  （`course_offerings` のときと同じ方針。`db/migrate/20261027100000` のコメントに記録がある）

### データ移行（`db/migrate/2026112400xxxx_merge_course_offerings_into_courses.rb`）

1つのmigrationで、`timetable_upload_rows` の科目選択列も落とす。順番に意味があるので、
この順で行う。

`up`：

1. `timetable_upload_rows` から `course_id` と `register_as_new` を落とす。
   **確認中の取り込みの行そのものは消さない。** PDFから読んだ文字列と「確認済み」のチェックは
   全部その列に残っており、落とすのは「既存の講義と被っているときの選択」だけなので、
   確認作業中のPDFはそのまま続けられる（被りの欄が消えるだけ）。
   この列を先に落とすことで、以降の手順で科目行の参照元が履修・計画の2つだけになる。
2. `courses` に★の列を足す（この時点ではindexもcheck制約も付けない）
3. 開講行を `courses` に移す。`course_offerings` を `course_id` ごとに古い順で見て、
   - **その科目の最初の開講行**で、かつ科目行が `curriculum_key` を**持たない**場合
     → その科目行をその場で更新する（`id` が変わらないので、履修・計画の参照が切れない）
   - **2件目以降の開講行**、または科目行が `curriculum_key` を**持つ**場合
     → 科目番号・科目名・単位をコピーした新しい行を作る。`created_at` / `updated_at` は
       開講行のものを引き継ぐ
   - **`curriculum_key` は絶対にコピーしない。** 便覧の科目行に開講情報を載せると、
     同じ科目を学期ごとに持てなくなる（`curriculum_key` の一意indexに当たる）。
     人が「既存の講義として扱う」で便覧の科目に開講情報を紐づけていた場合、その科目は
     便覧の行と開講の行の2行になる。取り込んだ行と便覧の科目の突き合わせは非ゴールなので、
     ここでは寄せない
4. 用済みになった科目行を消す：`curriculum_key` が無く、開講列も空で、`student_courses` /
   `planned_courses` からも参照されていない行。手順3の「その場で更新」により、ふつうは
   対象が無い。残した行があれば件数を `say` で知らせる
5. index（`(year, semester, lecture_code)` の部分unique）とcheck制約を足す。
   データを直したあとに付けることで、移行漏れがあればここで止まる
6. `course_offerings` を削除

`down`：`course_offerings` を作り直し、`courses` の開講列を持つ行を「科目行＋開講行」に戻し、
`timetable_upload_rows` に `course_id` と `register_as_new` を戻す（値は復元できないので既定値）。
統合前にあった「1科目に複数学期の開講」というまとまりは復元できず、開講1件につき科目1行になる。
その旨を `say` で知らせる。

### モデル

- `CourseOffering` を削除。その定数（`SEMESTERS` / `REQUIREMENT_TYPES` / `WEEKDAYS`）と検証を
  `Course` に移す。
- `Course`
  - `belongs_to :department, optional: true`
  - `has_many :course_offerings` を削除
  - 検証：`semester` は `SEMESTERS` に含まれる（空可）／`lecture_code` があるときは `semester` 必須／
    `lecture_code` は `(year, semester)` の中で一意（空可）／`requirement_type` `weekday` は
    選択肢に含まれる（空可）／`year` は1〜9999（空可）
  - `scope :offered` … `where.not(lecture_code: nil)`。「開講1件の行」を指す名前を1つ用意する
- `Department`：`has_many :course_offerings` → `has_many :courses`
- `TimetableUploadRow`：`belongs_to :course` と、科目の引き当てに関わるメソッドを削除
  （`course_candidates` / `course_choice_resolved?` / `default_course` / `assign_default_course_choice` /
  `course_choice` / `apply_course_choice` / `credits_mismatch_message`、`apply_edit` と `problems` の該当部分）
- `student_courses` / `planned_courses` のモデルとテーブルは変更なし

### 取り込み（TimetableImport）

ここがこの変更の本体。

- `timetable_upload_rows` から `course_id` と `register_as_new` を落とす（同じmigrationで行う）。
  同じ科目かどうかを人に選ばせる必要がなくなるため。確認中の取り込みは消さずに続けられる。
- `Importer`
  - 引き当てのキーは `(year, semester, lecture_code)` のまま。`find_or_initialize_by` で引いた
    `Course` に、科目番号・科目名・単位と開講列をまとめて入れる
  - 引き当てのキーに `lecture_code` が入るので、**取り込みが便覧由来の行（`lecture_code` が空）を
    引き当てることはない**。だから「選んだ既存の講義の単位と違う」エラーは不要になる。
    履修・計画が参照している行を取り込みが書き換える心配も、いまは無い
    （→「残る論点」を参照）
  - `resolve_course` / `linked_course` / `create_course` / `same_course_registered?` / `UNRESOLVED_MESSAGE` を削除
  - `Result` を `errors` / `created` / `updated` / `unchanged` / `applied` にする
    （`created_courses` と `created_offerings` を分ける意味がなくなる）
  - `RowAttributes` から `既存講義ID` / `新規登録` / `course_id` / `register_as_new` / `parse_course_id` を削除
  - 「講義コード◯◯は別の科目で登録済みです」のエラーは不要になる（1行に科目と開講が同居するため、
    同じ講義コードの行は上書き更新になる）
- `TimetableUploadRow#importer_values` から `既存講義ID` / `新規登録` を落とす
- `TimetableUpload#commit!` の呼び出し側（`TimetableUploadsController#commit`）の通知文を
  「講義の新規◯件・更新◯件」に直す

### 画面

- `app/views/timetable_uploads/show.html.erb`：「既存の講義と被っています」の行（選択欄ごと）を削除
- `app/helpers/timetable_uploads_helper.rb`：`course_choice_options` を削除
- `CourseOfferingSearch` → `CourseSearch` に改名。`Course` を直接引くので `joins(:course)` が不要になり、
  科目番号・科目名の部分一致も `courses` 自身の列に当たる。
  並び順（年度の降順、NULLは最後）と、年度・学部・学科・科目番号・講義コード・科目名の軸は変えない。
  便覧由来の行を一覧から外さない（#48 の設計どおり。年度・学期は「—」で出る）
- `CourseRegistrationsController`：一覧は `CourseSearch` 経由のまま。`@search_years` は
  `Course` から引く（すでに `.compact` しているので便覧行の影響を受けない）。
  `@any_offering` は **`Course.offered.exists?`** にする。この値は「まだ保存された講義はありません。
  『講義を追加』からPDFを取り込んでください」の案内と検索バーの出し分けに使われているので、
  `Course.exists?` にすると、便覧の科目が1件入った時点で案内が消え、年度も講義コードも空の行だけが
  並ぶ表が出てしまう。取り込んだ講義が1件でもあれば、便覧行も一覧に出る（#48 の方針どおり）
- `app/views/course_registrations/index.html.erb`：`offering.course.name` などを `course.name` に直す
  （表の列と見出しは変えない）

### 同じ科目を重複して算入しない

統合すると、同じ科目が学期ごと・年度ごとに複数行になる。判定が二重に数えないことは、
次の2つで担保する。

1. **`student_courses` / `planned_courses` が指すのは `curriculum_key` を持つ行だけ**。
   取り込んだ行に `curriculum_key` は付かない（付けるのは別issue）。`curriculum_key` には
   部分unique indexがあるので、1つの便覧科目に対応する行は必ず1行。したがって、学期ごとに
   増えた行が履修や計画から参照されることはない。
2. **判定は `curriculum_key` で突き合わせ、同じキーは1件にまとめる**。
   `GraduationAssessment::EntryNormalizer` はキーで `group_by` し、`Ledger#add` はキーで
   上書きするので、同じキーのエントリが複数来ても算入が2回になることはない。正確には
   2通りに分かれ、どちらも二重算入はしない。
   - 単位が一致する複数記録 → 1回だけ算入する
   - 単位が食い違う複数記録 → 算入0にして「同一科目の複数記録で単位数または承認が一致せず、
     再履修・読み替えの確認が必要」を立てる（`Ledger#quarantine`）

   これも既にそうなっている。両方の枝をテストで固定する（下記）。

### ドキュメント

- `docs/database-design.md`：ER図から `course_offerings` を消し、`courses` の説明を
  「便覧の科目と、授業時間配当表の開講1件が同じテーブルに入る」形に書き直す。
  `timetable_upload_rows` の説明から「既存の講義の選択（course_id / register_as_new）」を落とす。
  「科目・履修の同一性」の節に、講義の同一性が `(年度, 学期, 講義コード)` で決まることを足す。
- `docs/db-er-diagram.mmd`：同じ内容に直す。あわせて `departments ||--o{ students`（現在は
  `programs ||--o{ students`）のずれも直す。`docs/db-er-diagram.png` の再生成は行わない（別作業）。
- `README.md`：「講義登録」の節を直す。手順3（被りの選択）を削除して手順を繰り上げ、
  手順4の「`courses` と `course_offerings` に入る」と、節の末尾の
  「科目番号・科目名・単位は `courses`、…は `course_offerings` に入る」を統合後の形にする。
  取り込みの手順がここで変わるので、放置するとREADMEが画面と食い違う。

### テスト

- `test/models/course_offering_test.rb` → `test/models/course_test.rb`
  - 同じ年度・学期で講義コードは重複できない／年度が違えば登録できる
  - 便覧由来の行（開講列すべて空）は有効
  - 講義コードがあるのに学期が無い行はDBが拒否する（check制約）
- `test/services/course_offering_search_test.rb` → `test/services/course_search_test.rb`
  （中身は `Course` を直接作る形に書き換えるだけで、期待値は変えない）
- `test/lib/timetable_import/importer_test.rb`
  - 既存講義ID・新規登録・単位の食い違い・UNRESOLVED のテストを削除
  - 同じ名前・番号の講義が既にあっても、取り込みは止まらず別の行になることを確かめる
  - 同じ `(年度, 学期, 講義コード)` は更新、年度が違えば増える（既存のテストを統合後の形に）
  - 件数の期待値を `created` / `updated` / `unchanged` に合わせる
- `test/controllers/course_registrations_test.rb`：`course_choice` を送る／被りの選択を確かめる
  テストを削除。保存後の通知文の期待値を直す
- `test/services/graduation_assessment_test.rb`：同じキーの履修が複数あっても二重算入しないことを
  確かめるテストを足す（無ければ）。単位が一致する場合＝1回だけ算入、食い違う場合＝算入0で
  要確認が立つ、の両方。将来、取り込んだ行に `curriculum_key` を付けたときに効く防波堤になる
- `bin/rails test` と RuboCop が通ること

## 前提として確かめたこと

- いま `curriculum_key` を持つ `Course` を作るのは `test/test_helpers/sample_student.rb` だけで、
  アプリ側（`app/` / `db/seeds.rb` / `lib/tasks/master_data.rake`）には1つも無い。
  `DemoData` は `a39fa4f`「デモアカウントの入口を削除する」で消えている。
  `app/` には `student_courses` を作る経路も無い。つまり**本番の `courses` に入っているのは
  取り込んだ行だけで、`student_courses` / `planned_courses` は空**のはず。
- それでも便覧由来の行を前提に設計するのは、`plan_courses_controller.rb` が
  `Course.find_by(curriculum_key:)` で引いて無ければ `SetupIncomplete` を出す作りになっており、
  便覧の科目をDBに入れる経路が入ることは既に決まっているため。
  `course_offerings.rb` / `course_offering_search.rb` / `db/migrate/20261027100000` の
  コメントも、#53 のあとに `curriculum_key` 由来の行が同居することを前提に書かれている。
- したがって、移行の「履修・計画から参照されている行は残す」は、いまのデータでは効かない
  保険である。安い保険なので入れる。

## 残る論点（この変更では扱わない）

取り込んだ行に `curriculum_key` を付けて便覧の科目と突き合わせる別issueに入ると、
同じ行が「開講情報」と「履修・計画の参照先」を兼ねる。そうなると、PDFの単位欄を打ち間違えた
まま取り込み直すと、学生の記録済みの単位（`StudentCourse#assessment_entry` が読む
`course.credits`）が書き換わりうる。いまは取り込みが便覧行を引き当てられないので起きないが、
そのissueでは「履修・計画から参照されている行の科目番号・科目名・単位は上書きしない（または
取り込み前の確認に差分として出す）」ところまで決める必要がある。この設計書にその旨を残す。

## 作る人に委ねること

- migrationのファイル名のタイムスタンプ、SQLの書き方（`execute` か Active Record か）
- `scope :offered` の名前と、`Course` の検証の書き順
- テストメソッド名、テストの分割の細かさ
- `CourseSearch` 内部のメソッド分割（`narrow_by_text` が `joins` 不要になったあとの整理）

## 受け入れ条件との対応（#53）

| 受け入れ条件 | どこで満たすか |
| --- | --- |
| 統合後のテーブル名と列を決める | 「統合後のテーブル」 |
| 統合テーブルを作り `course_offerings` を廃止するmigration | 「データ移行」 |
| `student_courses` / `planned_courses` の参照先と重複算入 | 「同じ科目を重複して算入しない」 |
| 取り込みと授業登録画面の保存先を統合テーブルに | 「取り込み（TimetableImport）」「画面」 |
| `docs/database-design.md` のER図と表 | 「ドキュメント」 |
| 既存テストが通り、取り込みと判定のテストが統合後の構成に合う | 「テスト」 |
