# 便覧の下書きを確認して直し、公開する

読み取った下書きは、AIが書いたものなので、そのままでは学生の判定に使わない。
下書きの画面（`/curricula/:id`）で人が確認し、直してから公開する。

```
① PDFを読み取る → ② 要件表を確認する → ③ 科目表を確認する → ④ 公開する
```

①は取り込みのPRが受け持つ。このPRは②③④を足す。

## ② 要件表の確認

便覧の「章 → 枠 → 行 → 決まり」を画面の木にして出し、その場で直せるようにする。
直した値には人が確認した印（`confirmed`）を付け、読み直しでも上書きしない。送られなかった項目は消さない。

- 保存は1回の送信で画面全部。打ち間違いが1つあっても、送られた入力を残したまま画面を開き直し、問題を項目の下と上に出す。
  何百という欄を直した人に、すべてを打ち直させないため。
- 画面を開いたあとに中身が変わっていたら（読み取りが走ったなど）、いまの中身で開き直す。送られた入力は古い位置に
  結びついているので、そのまま当てない（`revision`）。
- 機械で見つかる誤りは「見つかった問題」として出す（`Validation`）。公開を止めるものと、警告だけのものを分ける。

## ③ 科目表の確認

科目は1科目ずつ確認する。484行を1回の送信で書き戻すと、別の科目の確認を巻き戻してしまうので、
その科目の位置だけを更新する（`CourseEdit::Storage` の jsonb_set / jsonb_insert）。

- 区分ごとに「まだ確認していない科目」をまとめて確認できる（`BulkConfirm`）。
- 科目番号から区分が決まる科目は、候補を採用すると科目表から外せる（`CoursePrune` / `PatternAdoption`）。
  人が確認した科目・手で足した科目は外さない。
- 読み落とした科目は手で足せる。PDFのページと見比べられるペインを表の上に出す。

## ④ 公開

公開できるかは `CurriculumImport::Publication` が1か所で決める。止める理由と警告を分け、警告があるときは
画面が見せた一覧の指紋（`acknowledged`）が無ければ公開しない（見ていない警告で公開させない）。

- 公開すると、確認用の欄・ページの記録・ページ画像を落とし、`published_at` を入れる。
- 同じ識別名・入学年度の公開済みがあるときは、差し替えを選んだときだけ置き換える。置き換わった旧版は下書きに戻る。
- 公開済みは書き換えない。直すときは「複製して直す」（`Duplicate`）で下書きを作り、直して公開して差し替える。

## 主なファイル

| 役割 | ファイル |
|---|---|
| 要件表の確認画面 | `app/views/curricula/_requirements_*.html.erb` / `app/helpers/requirements_review_helper.rb` |
| 要件表の保存 | `app/services/curriculum_import/requirements_edit/` / `curricula#update_rules` |
| 画面が見せるもの | `app/services/curriculum_import/requirements_review.rb` |
| 科目表の確認画面 | `app/views/curricula/_courses_*.html.erb` / `app/controllers/concerns/curricula_courses.rb` |
| 科目の保存 | `app/services/curriculum_import/course_edit.rb` |
| 絞り込み・候補の採用 | `app/services/curriculum_import/course_prune.rb` / `category_inference.rb` / `requirements_edit/pattern_adoption.rb` |
| 見つかった問題 | `app/services/curriculum_import/validation/` |
| 公開・複製 | `app/services/curriculum_import/publication.rb` / `duplicate.rb` |

## 直したものを守る約束

このアプリは「人が触ったものは、読み直しでも外さない」を守る。確認済みの科目、人が直した規則・章・行、
手で足した科目は、同じページを読み直しても戻らないし、消えない。読み直しで外れるのは、そのページの
読み取りが足したもの（`contributed`）だけ。
