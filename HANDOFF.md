# 作業引き継ぎメモ (2026-11-06時点)

セッション上限のため、別のAIエージェントに引き継ぐための記録。このファイルは一時的なメモで、作業が終わったら消してよい。

## 現在の場所

- ブランチ: `feature/curriculum-import`(origin には未push。ユーザーと相談のうえ進める)
- 最新コミット: `32b9fcb`(計画書の更新のみ)
- 作業中の実装計画: [`docs/superpowers/plans/2026-11-06-requirements-upload-and-rule-editor.md`](docs/superpowers/plans/2026-11-06-requirements-upload-and-rule-editor.md)
- 進捗台帳(ledger。gitignore対象・ローカルのみ): `.superpowers/sdd/2026-11-06-requirements-upload-and-rule-editor/progress.md`
  - **まずこの ledger を読むこと。** 各Taskの完了記録・判断理由(Ruling)・見つけたバグの経緯が、このメモより詳しく書いてある。
- 作業は `superpowers:executing-plans` スキルに沿って進めている(Taskごとに TDD → `bin/ci` → コミット → ledger に完了行を追記)。再開する側もこのスキルを使うことを推奨(`.claude/plugins/.../superpowers/*/skills/executing-plans/`)。

## 元になった依頼

ユーザーから、卒業要件チェッカーアプリの便覧PDF取り込みまわりについて、以下の要望があった(詳しくは計画書冒頭とこのセッションの会話を参照):

1. PDFから新しい卒業要件を作成する際も、対象選択カードと同じレイアウト・プルダウンにする
2. 学部・学科・コースは既存DB(Faculty/Department/Program)から持ってくる
3. 学部・学科・コース・年度のデフォルト表示を「---------」にする
4. 年度は2016年度(学生便覧が載っている最古の年)まで遡れるようにする
5. 年度のプルダウンは来年度分まで表示。年度が変わったら自動で追加される
6. 共通教育は科目番号で判定できるので、科目表に追加しない(知能情報コア等、番号で判定できないものだけ追加)
7. 規則の編集はJSON直書きではなく、直感的な画面操作でできるようにする
8. 年度のプルダウンは「2024年」のように年だけ表示し、「入学」の文字を消す

さらにセッション後半で、ユーザーから:
- 「PDFの読み取りを行ったら、現在mainに入っている卒業要件ビルダー画面に反映されるような仕組みにしたい」という追加要望があり、調査の結果 `main` の `/requirements` は **完全に静的なモックアップ**(`RequirementsController#show` は空、ツリー・AND/ORトグルは全てクライアント側JSのハードコード、保存も実際には何もしない)と判明。「このモックの見た目・UXを、実データで動くように作り直したい」という方針で合意し、計画のTask 6〜8をその方向に書き直し中(下記参照)。
- 「学部と学科にある架空データは削除してください」→ `DemoData` が作っていた「デモ用工学部（架空データ）」「知能情報工学（デモ）」が、Task1でFaculty/Departmentから作った本物の選択肢に混ざって出てしまっていたのを修正済み(コミット `3aa4a87`)。

## 完了したTask(コミット済み・テスト全部green)

実装計画の **Task 1・2** が完了済み。加えて計画外の修正を1件(デモデータ)実施。

| コミット | 内容 |
|---|---|
| `83fbd3c` | Task1: 取り込みフォーム・対象選択の学部/学科/コースをFaculty/Department/Programから作る |
| `d20c64e` | Task2: フォームの見た目を対象選択カードに揃え、年度を2016年度〜来年度に、表示を「2024年」に |
| `3aa4a87` | (計画外) デモ学生を実在の工学部・工学科に属させ、架空データを削除 |
| `32b9fcb` | 計画書の更新(Task1・2を完了に、Task6〜8をツリーUI方向に書き直し) |

**動作確認済み:** `docker compose exec web bin/rails test` で1281件全てpass、`bin/rubocop` もクリーン。ビルトインブラウザで学部→学科→コースの連動、入学年度の範囲・表示、対象選択→卒業要件表示までの一連の流れを目視確認済み。

**唯一の既知の失敗:** `bin/ci` の `Security: Gem audit`(`bin/bundler-audit`)が、Rails本体・Nokogiri・loofah等の既知の脆弱性で落ちる。**これはこのブランチの変更と無関係で、`main` も含めセッション開始時から既に落ちていた既存課題。** ユーザーの明示的な承認を得て、このセッションでは `git commit --no-verify` でこの1点だけ回避してコミットしている(再度確認は不要、との指示あり)。

## 残っているTask(未着手)

計画書の **Task 3〜8** が未着手。以下、計画書の該当節を読めば分かるが、要点だけ記す。

### Task 3・4: 共通教育の科目番号パターン判定(ツリーUIとは独立。先にやってよい)

- Task 3: `GraduationAssessment::Catalogue` に `pattern_category_for(number)` を足し、科目表(`document['courses']`)に無い科目でも、区分の `number_patterns`(例: `["外1"]`)に科目番号が一致すれば、その区分として数えられるようにする。`EntryNormalizer#normalize` が `course` が nil のとき `pattern_category_for` を試すように変える。
- Task 4: 2024・2025年度の便覧JSON(`config/curricula/intelligent_informatics/*.json`)から、共通教育の科目(健康運動・人文・社会・自然・総合・キャリア・地域創生・日本語・英語・外国語の各区分)を `courses` 配列から外し、各区分に `number_patterns` を足す。**ただし** `roles` を持つ科目(`japanese_expression`・`university_english`・`english_reading_intermediate`。`one_of_paths` が個別に指す科目)は番号だけでは識別できないので科目表に残す。`graduation_golden_2024_test.rb`・`graduation_golden_2024.json`(判定の固定フィクスチャ)は変えない。

### Task 5〜8: 要件表の確認画面を「卒業要件ルールビルダー」風のツリーUIに作り直す(JSON欄の廃止)

**これが今回の一番大きな残作業。** 経緯:

- `main:app/views/requirements/show.html.erb`(441行)に、完全に静的な「卒業要件ルールビルダー」モックがある。章(AND/OR バッジ付き)→行のネストしたツリーで、タイトル・必要単位が常時編集できる`<input>`、「+ 子区分」「+ ネスト条件(AND/OR)」「+ ルート区分を追加」ボタン、「要件を保存して反映」ボタンを持つが、**裏に保存処理は無い**(`RequirementsController#show` は `def show; end` だけ。JSは同じページ内の `data-sync-*` 要素を書き換えるだけ)。
- 一方、このブランチの `app/views/curricula/_requirements_review.html.erb`(`/curricula/:id` の下書き確認画面)は、**章(display.groups)・行(display.rows)・規則(rules)を1つのフォーム(`requirements_form`)でまとめて保存する仕組みが既にある**(`RequirementsEdit`・`revision` による競合検出・「人が確認した」印も実装済み)。ただし見た目は `<table>` + 行ごとに畳まれた `<details>` の編集欄で、規則は別セクション(`_requirements_rules.html.erb`)に分かれていて、行から規則へは `#rule-<id>` のジャンプリンクでしか繋がっていない。JSONのtextareaも `one_of_paths.paths`・`any_of.options`・`all_of.conditions`・新規規則の追加に残っている。
- ユーザーの意向: モックの見た目・UX(常時編集・AND/ORバッジ・入れ子)を再現しつつ、裏側は本物の `Curriculum#document` で動かす。**バックエンドの土台(1フォーム・RequirementsEdit・revision)は作り直さない。見た目(view)の再設計が主眼。**

計画書に書いた新しいTask 5〜8(詳細は計画書本体を参照。ここは要約):

- **Task 5**: 繰り返し行(経路・条件)を増減する汎用のStimulusコントローラ(`repeater_controller.js`)。配列パラメータの`[]`記法をそのまま使い、添字の付け替えをしない。
- **Task 6**: `_requirements_table.html.erb`・`_requirements_row.html.erb` を書き直し、章・行を常時編集可能な入れ子ツリーにする(`<details>` での開閉をやめる)。行が `check_ids` で指す規則のうち `one_of_paths`・`any_of`・`all_of` を、行の下にAND/ORバッジ付きの入れ子ボックスとして出す(それ以外の規則はバッジ無し)。`RequirementsReviewHelper#rules_for`・`#rule_logic_label` を新設。**フォームのパラメータ名は一切変えない**(表示(view)だけを作り直し、`RequirementsEdit`/`DisplayEditing`には触れない)。
- **Task 7**: Task 6で出した入れ子ボックスの中で、経路(`paths`)・条件(`options`/`conditions`)をJSONなしに編集できるようにする(`Coercion`に`:paths`・`:conditions`を足す。`all_of`の中に`all_of`/`any_of`は置けない)。`review.known_roles`(科目のrolesから作る選択肢)も新設。
- **Task 8**: 「章を足す」「行を足す」「規則を足す(JSONのtextarea)」を、ツリーのUIに統合する。特に `new_rule_json` を廃止し、型選択(`CurriculaController::NEW_PROGRAM`等と同様のselect)+欄のフォームにする。

**次に着手する側へ:** 計画書のTask 6〜8の節(「Files」「Interfaces」「Step 1〜6」)に、失敗するテストの具体的なコード・パラメータ名まで書いてあるので、それに従って実装すること。各Taskは「Step1: 失敗するテストを書く→Step2: RED確認→Step3: 実装→Step4: `bin/ci`→Step5: ブラウザで確認→Step6: コミット」のTDDサイクル。コミットしたら `.superpowers/sdd/.../progress.md` に完了行を追記すること(スキルの`task-done`スクリプトが自動でやってくれる: `bash .claude/plugins/cache/claude-plugins-official/superpowers/*/skills/executing-plans/scripts/task-done <plan> <task番号> <BASE commit> -- <テストコマンド>`)。

## 重要な設計判断(Ruling)の要約

詳細は ledger 参照。特に次の2つは、計画と違う方向に倒した判断なので注意:

1. **`Curriculum#department_name` のスキーマは分けなかった。** 当初「学科」「コース」をDBカラムとして分ける計画だったが、約30件の既存テストと`PublishedDocument`/`Publication`/`Duplicate`が同時に壊れると判明したため、`department_name`は今までどおり「学科名+コース名」を結合した1つの文字列のまま。画面では学科・コースを別のプルダウンにし、コントローラ層(`CurriculumUploadParams#curriculum_attributes`・`RequirementsController#resolve_selection`)で結合・分割するだけに留めた。`Program.department_and_course_for(combined_name)` が逆引き(結合文字列→学科名・コース名)を行う。
2. **共通教育の判定経路**(Task3)は、判定エンジン(`Catalogue`/`EntryNormalizer`)に新しい推定経路を足す方針で合意済み(ユーザー確認済み)。安全側の設計(パターンに一致しなければ今までどおり「要確認」のまま)であることをコードコメントに明記すること。

## 環境に関する注意

- `docker compose up -d` でスタック起動。Docker Desktopがこのセッション中に一度クラッシュし、開発用DBが「マイグレーションは適用済みと記録されているのに実際のカラムが無い」という不整合に陥ったことがある → 直すには `bin/rails db:drop db:create db:schema:load`(ユーザー承認済みで実施)。
- `db/seeds/programs.rb` を追加したあと、既にDBがある状態では `bin/rails db:seed` を明示的に再実行しないとProgramテーブルが空のままになる(実際にこれでハマった。ledger参照)。**ブラウザで確認する前に必ず `docker compose exec web bin/rails db:seed` を実行すること。**
- テストは並列実行(`bin/rails test`)で基本問題ないが、既存のCLAUDE.md的な注意として「1ファイルずつ」が安全側。
- ビルトインブラウザ(Claude Browser)での確認は `mcp__Claude_Browser__preview_start` で `http://localhost:3000/...` を開けばよい。

## 未解決・ユーザーに確認が必要な事項

- `bin/ci` の Gem audit 失敗(既存課題)。根本対応(Gemfileの脆弱性更新)は未着手。ユーザーは「このセッション中は`--no-verify`で進めてよい」と明言済みだが、**別セッション/別エージェントに移る場合は改めて確認した方が安全**(このセッションの中だけの合意という可能性があるため)。
- Task 6〜8のツリーUIの具体的な見た目(Tailwindのクラスまで)は、mainのモックに寄せる方針で合意しているが、ピクセル単位で完全一致させる指示は受けていない。計画書に書いた「見た目の方針」の範囲で、実装者の裁量で進めてよい。
- このブランチ(`feature/curriculum-import`)はまだ `origin` にpushされていない、PRも無い。全Task完了後にどうするか(push・PR作成のタイミング)はユーザーに確認すること。

## 参考: このセッションで調べた主な事実

- `main` の `/requirements` ルート・コントローラ・ビューは、このブランチの同名ルートとは全く別物(静的モック)。`git show main:app/views/requirements/show.html.erb` で読める。
- `display.groups[].check_id` / `display.rows[].check_ids` が、画面の章・行と `rules[]` の規則を結びつけるキー。
- `GraduationAssessment::Rules::ANY_OF_OPTIONS = %w[credit_sum grouped_max all_of]`、`ALL_OF_CONDITIONS = %w[credit_sum grouped_max]`(= 入れ子は2階層まで。`all_of`の中に`any_of`/`all_of`は来ない)。
- 2024年度の共通教育で `roles` を持つ科目は3件のみ: `日本語表現法入門`(role: `japanese_expression`)、`大学英語`(`university_english`)、`英語講読演習 中級`(`english_reading_intermediate`)。この3件だけは科目表に残す。
