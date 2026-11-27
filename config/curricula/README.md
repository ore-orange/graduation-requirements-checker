# 卒業要件データと判定の契約

要件文書は`config/curricula/<slug>/<admission_year>.json`に置く。現在の対象は`intelligent_informatics/2024.json`（琉球大学 工学部 工学科 知能情報コース、2024年度入学）。`slug`はコース（`Program#curriculum_slug`）が指す識別名で、学科名・コース名・プログラム名と同一視しない。

このファイルは`curricula`表に公開済みの便覧として入れる初期データで、アプリが実行時に読むのはDBの行。`db:seed`とデプロイで流す`master:load`が`CurriculumFiles.load!`を呼び、同じslug・入学年度の公開済みが無いときだけ作る。既にある行は書き換えないので、ファイルを直してDBに反映したいときは該当の行を消してから流し直す。

```ruby
curriculum = Curriculum.find_published(slug: 'intelligent_informatics', admission_year: 2024)
curriculum.document # => 要件文書のHash
Curriculum.published_years('intelligent_informatics') # => [2024]
```

学生の便覧は`Student#curriculum`が、コースのslugと入学年度から公開済みの行を引いて返す。無ければ`SetupIncomplete`になる。学部階層やプログラム別ファイルの合成は導入していない。

## 出典と対象範囲

- [提供されたコース別学生便覧](../../docs/kogaku_chinot_y24.pdf)：提供科目・分類・必修・卒業要件。
- [公式2024年度 共通教育等授業科目表](https://rais.skr.u-ryukyu.ac.jp/wordpress/wp-content/uploads/binran/R6/01gakubu/01kyotsu/00-04kyotsu_jugyokamoku.pdf)：標準の共通教育・専門基礎科目の番号・単位・区分・言語。
- [公式2024年度 共通教育等授業科目講義内容](https://rais.skr.u-ryukyu.ac.jp/wordpress/wp-content/uploads/binran/R6/01gakubu/01kyotsu/00-05kyotsu_koginaiyo.pdf)：指定英語・健康運動科目の詳細。

各文書のURL・ページ・照合上の注意をJSONの`sources`に保持する。外国人学生の日本語・日本事情の特例科目と、医学科専用の先07統計学は対象外。共通教育表にない他学部の全提供科目まで網羅するものではない。

知能327の重複印刷は1科目として登録する。知能情報特別講義Ⅴ・Ⅵは分類表にある一方、番号・単位の掲載がないため、その項目は`null`と確認理由を保持する。未確認の値を作らない。

## 文書形式（format_version: 2）

| フィールド | 内容 |
| --- | --- |
| `department` / `admission_year` / `title` | 対象の取得キー・入学年度・表示名 |
| `sources` | 一次資料の識別子・タイトル・URL・ページ・注意点 |
| `categories` | 区分の`key`と和名`label` |
| `display` | 画面の章・行・小計と卒業総単位。見せ方だけで、卒業要件そのものではない |
| `rules` | 卒業要件の条件と、算入を変える調整。下記の「規則（rules）」 |
| `courses` | 科目別の正規キー・番号・名称・単位・区分・必修フラグ・提供コース・言語・role・出典・確認理由・承認条件・選択可否 |

`courses[].key`は、DB連番や名称検索に依存しない明示的な参照キー。`Course.curriculum_key`と対応させる。科目番号や名称が一致するだけでは別科目を同一視しない。

`credits`は一次資料の所定単位で、未確認なら`null`。`review_reason`は未確認の理由。`requires_approval`は学生別の承認確認が必要なことを示す規則であり、承認済みという事実ではない。自コース提供の工学融合等は`selectable: false`とする。

便覧の形式検証はJSONオブジェクトであることまでであり（`Curriculum`の検証）、JSON Schemaはまだ導入していない。判定のしかたはコードではなく`rules`が決める。年度ごとの判定の根拠は[判定設計](../../docs/graduation-rules-2024.md)に残す。

### 規則（`rules`）

`GraduationAssessment`は`rules`を解釈するだけで、区分名・必要単位・文面をコードに持たない。条件は1つのチェックになり、`id`・`label`・`source`・`detail`を持つ。`id`は`display`の`check_id(s)`から参照されるので、変えると画面の行が判定を見失う。

| `type` | 判定 | 主な欄 |
| --- | --- | --- |
| `credit_sum` | 指定した区分の算入単位の合計が`required_credits`に届くか | `categories`・`required_credits` |
| `grouped_max` | 区分の算入単位を科目の欄の値で分け、最大のグループが`required_credits`に届くか。グループを合算しない | `category`・`group_by`（`field:<欄名>`）・`missing_group_note` |
| `one_of_paths` | roleの組で表した経路のうち、どれか1つを丸ごと満たすか。2つ以上の経路に算入済みの科目があれば、全役割を外して`review_note`を注記する | `paths`・`review_note` |
| `all_required` | `courses[].required`の科目をすべて修得しているか。必修の数や区分が控えと合わなければ要確認 | `expected_course_count`・`required_credits`・`required_categories` |
| `any_of` | `options`のどれか1つを満たすか。`detail`に入れ子の条件の値を`{{id}}`で差し込める | `options`・`counted_from` |
| `all_of` | `conditions`をすべて満たすか。`any_of`の選択肢としてだけ置ける | `conditions` |

知らない`type`や置けない位置の条件は、例外にせず必ず要確認にする（解釈できない規則を充足と答えないため）。

調整はチェックを作らず、条件を評価する前に算入を変える。壊れた調整は読み込む時点で`ArgumentError`にする。

| `type` | はたらき | 欄 |
| --- | --- | --- |
| `cap` | 区分の算入単位を`credits`で打ち切る。キー順に配分し、打ち切った科目に`reason`を残す | `category`・`credits`・`reason` |
| `exclude` | 当たった科目を算入しない。`field`があれば、その欄が`value`と一致した科目だけに当たる | `category`・`reason`・`field`・`value` |

2024年度の判定結果は`test/fixtures/files/graduation_golden_2024.json`に記録し、`test/services/graduation_assessment/golden_test.rb`が照合する。規則を直して判定を意図して変えたときだけ、`bin/rails graduation:golden`で記録を書き直す。

## 判定Interface

```ruby
result = GraduationAssessment.new(curriculum: curriculum).call(
  completed: [], registered: [], planned: [], unresolved: []
)
```

入力の各配列は、`key`・`credits`・`approved`・`name`のSymbolキーを持つHash。`completed`は実際の修得単位、`registered`・`planned`は修得を仮定する所定単位を渡す。`unresolved`は履修状態が確認できない記録で、単位は推測しない。Controllerが`StudentCourse.enrollment_status`に従って明示的に振り分ける。

戻り値は`actual`と`projected`のSnapshot。Snapshotは`status`（`:satisfied` / `:unmet` / `:needs_review`）、`counted_credits`、条件ごとの`checks`、`review_notes`、科目ごとの`course_results`を返す。

同一キーの修得済み科目を予定に重ねても増加させない。修得単位の競合や未確認の代替関係は勝手に最大値・最新値を選ばない。算入対象外と確定した科目は、履修状態が不明でも0単位の除外理由を表示し、その記録だけを理由に最終判定を要確認にはしない。

## DBに置く便覧の契約

`Curriculum`はslug（小文字英数字とアンダースコア、先頭は英字）、admission_year（1〜9999の整数）、`document`（JSONのオブジェクト）を持つ。公開済み（`published_at`あり）は同じslug・入学年度に1つだけで、学生の判定に使うのはこれだけ。公開していない行は何件でも置ける。ファイル名が入学年度でないファイルや読めないJSONは、`CurriculumFiles.load!`がパスを添えた`ArgumentError`にする（本文はメッセージに含めない）。

## デモ履修データとの分離

`test/fixtures/files/sample_enrollments.json`は判定テスト用の人工的な履修記録であり、要件文書とは分ける。`SampleStudent.load!`がテスト実行時に、一次資料由来の科目マスタと人工履修データをテストDBへ登録する。

将来計画は`PlannedCourse`へ保存する。履修履歴の年度必須制約を迂回するための架空の年度は使わない。デモの起動・操作は[README](../../README.md#ローカルデモ)を参照。
