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

## 文書形式（format_version: 1）

| フィールド | 内容 |
| --- | --- |
| `department` / `admission_year` / `title` | 対象の取得キー・入学年度・表示名 |
| `sources` | 一次資料の識別子・タイトル・URL・ページ・注意点 |
| `requirements` | 指定英語・日本語表現法入門・微分積分の二系列・物理の代替科目を識別するrole |
| `courses` | 科目別の正規キー・番号・名称・単位・区分・必修フラグ・提供コース・言語・role・出典・確認理由・承認条件・選択可否 |

`courses[].key`は、DB連番や名称検索に依存しない明示的な参照キー。`Course.curriculum_key`と対応させる。科目番号や名称が一致するだけでは別科目を同一視しない。

`credits`は一次資料の所定単位で、未確認なら`null`。`review_reason`は未確認の理由。`requires_approval`は学生別の承認確認が必要なことを示す規則であり、承認済みという事実ではない。自コース提供の工学融合等は`selectable: false`とする。

Repositoryの形式検証はJSONオブジェクトであることまでであり、JSON Schemaはまだ導入していない。卒業単位の条件式は、当該年度専用の`GraduationAssessment`と[判定設計](../../docs/graduation-rules-2024.md)で管理する。汎用のルールDSLではない。

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
