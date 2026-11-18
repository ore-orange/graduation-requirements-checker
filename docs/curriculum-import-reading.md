# 便覧PDFの取り込みと読み取り

便覧のPDFを上げて下書きを作り、どのページを読むかを人が決めて、1ページずつAIに読ませる。
入口は卒業要件の確認画面（`/requirements`）、作業するのは下書きの画面（`/curricula/:id`）。

下書きを人が直す画面と、公開は、この上に積む別のPRで足す。

## 流れ

```
① PDFを上げる        … ページ画像とページごとの文字を取り出し、PDFは捨てる
② 読むページを決める  … 1ページずつ見て「読まない・要件表・科目表」から選ぶ
③ 読み取る            … 選んだページを1ページずつ読み、結果を下書きの document に入れる
```

## PDFから取り出すもの

アップロードと同じリクエストの中で、Ghostscript でページ画像（PNG）を作り、ページごとの文字を取り出す。
PDFそのものは残さない（置くのは画像と文字だけ）。取り出せなくても下書きは残し、何が取れなかったかを
`curricula.import_error` に書く。ページ数を数えられなければ、人がページ数を指定して始められる。

- ページ画像は `storage/curricula/<環境>/<下書きのid>/p<ページ番号>.png`。下書きを消すと、この置き場ごと消える。
- 画像は `GET /curricula/:id/page_image/:page` で返す。パスは下書きのidとページ番号からだけ組み立てる。

## 読むページの指定

ページの種別は `curricula.pages` に持つ（`[{ page:, kind:, status:, error:, text:, contributed: }]`）。
取り込み直後はすべて `skip`。画面は1ページずつ大きく見せ、キーボードでも選べる（`page_wizard_controller.js`）。
「この指定で読み取る」を押すと、保存してからそのまま読み取りに入る（`read_pages_controller.js`）。

種別を替えたページは、読み取りの結果を文書から外して未読に戻す。気づかないまま消えないよう、どのページを
外したかを知らせる。確認済みの科目と、人が直した規則・章・行は残す。

## 読み取り（AI）

`CurriculumReader` が窓口。鍵（`CURRICULUM_READER_API_KEY`）が無ければ読み取りのボタンを出さない。
学生の履修・成績は渡さない。渡すのはページ画像とそのページの文字、区分・役割の一覧だけ。

読み取りは外部APIの呼び出しで数秒〜数十秒かかる。バックグラウンドには回さず、画面が1ページずつ順に呼ぶ。
結果を入れるときだけ行をロックし、そのときの最新の文書に統合する（待っている間に人が確認した科目を消さないため）。

## 読み取った結果の入れ方（DraftMerge）

読み直しても、人が触ったものは上書きしない。

- 人が確認した科目（`confirmed`）と、人が手で足した科目は残す。
- 科目番号から区分が決まる科目は、便覧の科目表に持たない（`CourseFilter`）。人が確認した科目は落とさない。
- 科目番号と科目名が同じ重複は登録しない。
- ページごとに「このページが足したもの」（`contributed`）を覚えておき、読み直しのときはそれだけを外す。

## 主なファイル

| 役割 | ファイル |
|---|---|
| 画面 | `app/controllers/curricula_controller.rb` / `app/views/curricula/` |
| アップロードの入口 | `app/views/requirements/_upload.html.erb` / `app/helpers/upload_form_helper.rb` |
| 下書きの一覧 | `app/views/requirements/_drafts.html.erb` |
| PDFからの取り出し | `app/services/curriculum_import/page_source.rb` / `png_files.rb` / `gs_runner.rb` / `page_text.rb` |
| ページの指定 | `app/controllers/concerns/curricula_pages_update.rb` / `app/javascript/controllers/page_wizard_controller.js` |
| 読み取り | `app/services/curriculum_import/read_page.rb` / `app/services/curriculum_reader/` |
| 下書きへの統合 | `app/services/curriculum_import/draft_merge/` |
| 読み直しの警告 | `app/services/curriculum_import/reread_warning.rb` |

## 環境

Ghostscript が要る。`compose.yml` のイメージには入っている。読み取りの鍵は `.env` の
`CURRICULUM_READER_API_KEY`（無ければ、ページの指定までは使える）。
