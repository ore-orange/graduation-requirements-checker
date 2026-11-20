# 卒業要件の確認画面（デフォルト）

`/requirements`。学部・学科コース・入学年度を選ぶと、その便覧に書かれた卒業要件を読み取り専用で見せる。
学生の便覧ではなく、選んだ組み合わせから便覧を引く。ログインしていれば誰でも開ける。

この画面は便覧を「見る」ところまでを受け持つ。PDFからの取り込み（読み取り）と、下書きの修正（編集）は別の画面で、
それぞれ別のPRで足す。

## 画面の流れ

```
対象を選ぶ（学部 → 学科 → コース → 入学年度）
   └ 公開済みの便覧がある  … 卒業要件のカード（総単位 → 章 → 枠 → 行 → 決まり）と科目表を出す
   └ 無い                  … 「この年度の便覧はまだありません」と伝える
```

## 便覧はどこにあるか

便覧は `curricula` テーブルの1行で、中身は `document`（JSONB）が持つ。`published_at` のある行が公開済みで、
学生の卒業判定に使われる。下書き（`published_at` が nil）は取り込み途中の作業中の文書なので、どの判定にも使わない。

- 種は `config/curricula/<識別名>/<入学年度>.json`。`bin/rails db:seed` が `Curriculum.seed_from_file` で入れる。
  開発・テストではファイルの内容で上書きし、本番では既存の行に触れない（公開済みになった時点でDBが正本）。
- 学生は `students.curriculum_id` で便覧を指す。引き当てるのはコースの識別名（`programs.curriculum_slug`）と入学年度で、
  学生を作るときに1回だけ引く（`Student#assign_curriculum`）。公開前の便覧は指せない。
- 識別名（slug）は人に入力させない。DBの内部キーなので、画面にも出さない。

## 主なファイル

| 役割 | ファイル |
|---|---|
| 画面 | `app/controllers/requirements_controller.rb` / `app/views/requirements/` |
| 選択肢と、選んだ値の解釈 | `app/services/curriculum_choices.rb` / `curriculum_selection.rb` |
| 便覧のレコード | `app/models/curriculum.rb` / `db/migrate/20261030*`・`20261105*` |
| 要件のカードの組み立て | `app/helpers/requirement_cards_helper.rb` / `requirement_rule_cards_helper.rb` |
| 規則を一文にする | `app/helpers/rule_sentence_helper.rb` / `rule_trimming_helper.rb` |
| 学生に見せる科目の名簿 | `app/services/course_directory.rb` / `course_number.rb` |
| 卒業判定 | `app/services/graduation_assessment/` |
| 文書の検査と画面の木 | `app/services/curriculum_import/validation/` / `requirements_review/tree.rb` |

## 卒業判定（GraduationAssessment）

便覧の `rules` を、型ごとの規則オブジェクト（`GraduationAssessment::Rules::*`）に組み立てて評価する。
型は `credit_sum`・`any_of`・`all_of`・`all_required`・`one_of_paths`・`grouped_max`・`cap`・`exclude` と、
読めない型のための `unknown`。学科ごとの決め打ちの判定クラスは持たない（便覧の文書だけで決まる）。

判定が変わっていないことは、記録との突き合わせで見張る。

```bash
bin/rails test test/services/graduation_assessment_golden_test.rb
```

記録の作り直しは `bin/rails graduation:golden`。判定を意図して変えたときだけ流す。

## 科目の名簿（CourseDirectory）

「この区分には、どんな科目があるか」に答える。科目の実体は `courses` テーブルで、便覧の文書はその科目に区分の札を貼る側。
札は2通りある。

1. 便覧に登録された科目（番号から区分が決まらないもの）… 登録の区分・必修・承認・選べるかを正とする
2. 登録の無い科目 … 科目番号を区分の `number_patterns` に掛けて決める。決まらなければ名簿に出さない

`db/course_master.json` は科目の種。便覧JSONから作り直せる。

```bash
bin/rails course_master:build
```

便覧JSONの科目を直したり、年度の便覧を足したりしたら流し直して、できたファイルもコミットする。

## 指導教員の承認

便覧が「承認が要る」と書いている科目は、学生が「承認あり／なし／未回答」に答える（`PATCH /approvals`）。
未回答のままなら判定は要確認のままで、黙って算入しない。対象は履修記録（`student_courses`）と履修予定
（`planned_courses`）のどちらか一方で、`kind` で見分ける。
