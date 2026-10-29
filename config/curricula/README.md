# 卒業要件データと判定の契約

要件文書は`config/curricula/<department_slug>/<admission_year>.json`に保存する。現在の対象は`intelligent_informatics/2024.json`（琉球大学 工学部 工学科 知能情報コース、2024年度入学）。取得キーの`department`はRepositoryの既存Interface名であり、DB上の学科名・コース名・プログラム名を同一視するものではない。

```ruby
curriculum = CurriculumRepository.find(department: 'intelligent_informatics', admission_year: 2024)
```

この呼び出しは登録済みのHashを返す。未登録の対象は`NotFound`になる。学部階層やプログラム別ファイルの合成、JSONB保存は導入していない。

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
| `categories` | 区分の`key`・和名`label`・卒業総単位に数えるか`counts_toward_total` |
| `rules` | 卒業要件の条件と、算入を変える調整。下記のルールDSL |
| `display` | 画面の章・行・小計の組み立て。要件そのものではなく見せ方 |
| `courses` | 科目別の正規キー・番号・名称・単位・区分・必修フラグ・言語・role・出典・確認理由・承認条件・選択可否 |

判定のしかたはコードではなくこのJSONが決める。`GraduationAssessment::Evaluation`は`rules`を並び順に解釈するだけで、区分名も必要単位も文面もコードには持たない。2024年度の便覧は22区分・27規則（条件24・調整3）を持つ。

`courses[].key`は、DB連番や名称検索に依存しない明示的な参照キー。`Course.curriculum_key`と対応させる。科目番号や名称が一致するだけでは別科目を同一視しない。

`credits`は一次資料の所定単位で、未確認なら`null`。`review_reason`は未確認の理由。`requires_approval`は学生別の承認確認が必要なことを示す規則であり、承認済みという事実ではない。自コース提供の工学融合等は`selectable: false`とする。`number`は科目番号で、一次資料に無ければ`null`。`language`は外国語科目の言語で、一外国語の集計はこの欄で分ける（科目番号の百の位では分けない。外7xxにはインドネシア語・タイ語・ラテン語・ロシア語が混ざる）。

Repositoryの形式検証はJSONオブジェクトであることまでであり、JSON Schemaはまだ導入していない。年度ごとの判定の根拠は[判定設計](../../docs/graduation-rules-2024.md)に残す。

### 規則（`rules`）

各規則は`id`・`type`を持つ。条件はさらに`label`（画面の見出し）・`source_page`（根拠の出典）・`detail`（説明文の前半。コードが「確認済み算入○／必要○単位。」を後ろに足す）を持つ。`id`は`display`の`check_ids`から参照されるので、変えると画面の行が単位を見失う。

条件は7種類。

| `type` | 判定 | 主な欄 |
| --- | --- | --- |
| `credit_sum` | 指定した区分の算入単位の合計が`required_credits`に届くか | `categories`・`required_credits` |
| `all_required` | `courses[].required`の科目をすべて修得しているか。余剰単位による代用は不可 | `expected_course_count`・`required_credits`・`required_categories` |
| `one_of_paths` | roleの組で表した経路のうち、どれか1つを丸ごと満たすか | `paths`（roleの配列の配列）・`review_note` |
| `grouped_max` | 区分の算入単位を`group_by`でグループに分け、最大のグループが`required_credits`に届くか。グループを合算しない | `category`・`group_by`・`group_label`・`required_credits` |
| `any_of` | `options`のどれか1つを満たせばよい | `options` |
| `all_of` | `conditions`をすべて満たす。`any_of`の選択肢としてだけ置ける | `conditions` |
| （未対応の`type`） | 充足とは答えず、必ず要確認にして理由を残す | — |

`grouped_max`の`group_by`は`number_prefix`（科目番号の接頭辞。提供コースを表す）、`number_prefix_hundreds`（接頭辞＋百の位）、`field:<欄名>`（`field:language`など、科目の欄の値）のいずれか。グループを決められない科目（番号が読めない、欄が空）は最大値に算入せず、`group_label`を使った要確認の注記を残す。

入れ子は`any_of` → `all_of`の2段まで。`any_of`の選択肢に置けるのは`credit_sum`・`grouped_max`・`all_of`、`all_of`の条件に置けるのは`credit_sum`・`grouped_max`。それより深い位置や置けない`type`の規則は、例外にはせず要確認にする（解釈できない規則を充足と答えないため）。

`all_required`の`expected_course_count`・`required_credits`・`required_categories`は、科目表の転記漏れを見張るための控え。科目表の必修の数・単位合計がこの値と合わないとき、または必修の科目が`required_categories`の外の区分に入っているときは、不足ではなく要確認にする。区分の取り違えは科目数も単位合計も合ったまま通ってしまい、その単位が選択の集計にも流れ込んで二重に数えられる。

`one_of_paths`で複数の経路に算入済みの役割があるときは、組合せと重複算入を確認できるまで、その経路の全役割を算入から外して`review_note`の文面を残す。

### 調整（`rules`のうち`cap`・`exclude`）

調整は判定を作らず、条件を評価する前に算入そのものを変える。`rules`の中に条件と混在して置ける（`display`の順に合わせるため、並び順は保たれる）。

| `type` | はたらき | 欄 |
| --- | --- | --- |
| `cap` | 区分の算入単位を`credits`で打ち切る。正規キー順に配分し、打ち切った科目に理由を残す | `category`・`credits` |
| `exclude` | 当たった科目を算入の対象にしない | `category`・`reason`・`number_prefix`（任意） |

`exclude`は`category`が一致した科目に当たる。`number_prefix`があれば科目番号の接頭辞も一致した科目だけに絞る（自コース提供の工学融合は`category: fusion` + `number_prefix: 知能`）。科目番号が読めない科目は接頭辞の規則に当たらない。読めないことは、その接頭辞に属する根拠にならない。

壊れた調整は黙って落とさず、便覧を読み込む時点で`ArgumentError`にする。`cap`の`credits`が0以上の有限な数でない場合と、`exclude`の`category`・`reason`が空、`number_prefix`が空白や全角を含む場合。

### 画面の組み立て（`display`）

`total_credits`は卒業に必要な総単位。`groups`は画面の章で、章ごとに`title`・`required_credits`・`check_id`と、行`rows`を持つ。行は`name`・`subtitle`・`required_credits`・`required_label`・`categories`（その行に集める区分）・`check_ids`（その行に出す判定）・`credits_from_check`（単位を区分の合計ではなく判定の値から取るか）を持つ。`subtotals`は複数の行にまたがる小計。

`display`は見せ方だけを持ち、卒業要件そのものは`rules`にある。両者の対応（`check_ids`の綴り、どの行にも出ない区分）は`test/services/graduation_assessment/handbook_integrity_test.rb`が見張る。

**`display`はまだどの画面からも読まれていない。** 画面の章・行・小計は現在もRubyの定数（`StudentWorkspaceHelper::PLANNER_GROUPS`ほか）が組み立てており、`display`を編集しても表示は変わらない。画面をこのデータから組み立てる差し替えは別のタスクで行う。

### 読み込み時に弾くもの

`Catalogue`は`format_version: 2`の便覧を読むとき、次を検めて外れていれば例外にする。壊れた便覧が正しく見えたまま、学生の判定を狂わせないため。

- `courses`の`number`に重複がある（`ArgumentError`）。同じ番号の科目が2つあると、学生の履修が違う科目に解決される。空・`null`の`number`は弾かない（知能情報特別講義Ⅴ・Ⅵは分類表にしか載っておらず、意図的に番号を持たない）
- `categories`の要素に`key`が無い、または`key`が重複している（`ArgumentError`）
- `rules`が`categories`に無い区分を参照している（`ArgumentError`）。入れ子の`options`・`conditions`もたどる
- `cap`・`exclude`の定義が壊れている（`ArgumentError`）
- `one_of_paths`に`paths`が無い（`KeyError`）

## 判定Interface

```ruby
result = GraduationAssessment.new(curriculum: curriculum).call(
  completed: [], registered: [], planned: [], unresolved: []
)
```

入力の各配列は、`key`・`credits`・`approved`・`name`のSymbolキーを持つHash。`completed`は実際の修得単位、`registered`・`planned`は修得を仮定する所定単位を渡す。`unresolved`は履修状態が確認できない記録で、単位は推測しない。Controllerが`StudentCourse.enrollment_status`に従って明示的に振り分ける。

戻り値は`actual`と`projected`のSnapshot。Snapshotは`status`（`:satisfied` / `:unmet` / `:needs_review`）、`counted_credits`、条件ごとの`checks`、`review_notes`、科目ごとの`course_results`を返す。

同一キーの修得済み科目を予定に重ねても増加させない。修得単位の競合や未確認の代替関係は勝手に最大値・最新値を選ばない。算入対象外と確定した科目は、履修状態が不明でも0単位の除外理由を表示し、その記録だけを理由に最終判定を要確認にはしない。

## Repository取得の契約

`find(department:, admission_year:)`はHashを返す。departmentは小文字英数字とアンダースコアのslug（先頭は英字）、admission_yearは1〜9999のInteger。

`InvalidInput`、`NotFound`、`InvalidDocument`、`ReadError`はいずれも`CurriculumRepository::Error`。ファイルの場所やパース元本文はエラーに含めない。symlinkを含む保存ディレクトリ外への参照を拒否する。

## デモ履修データとの分離

`db/demo_enrollments.json`は人工的な学生の修得・登録済み・履修中の記録であり、要件文書とは分ける。`DemoData.load!`が明示的なseed実行時に、一次資料由来の科目マスタと人工履修データを開発・テストDBへ登録する。保存済み将来計画、無関係な学生・科目・履修行は削除しない。

将来計画は`PlannedCourse`へ保存する。履修履歴の年度必須制約を迂回するための架空の年度は使わない。デモの起動・操作は[README](../../README.md#ローカルデモ)を参照。
