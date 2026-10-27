# graduation-requirements-checker

琉球大学の卒業要件チェッカー

## 開発対象（合意事項）

- 対象：琉球大学 工学部 工学科 知能情報コースの2024年度入学生。
- 判定：修得済みの科目・単位による「実績判定」と、履修予定科目をすべて修得した場合の「見込み判定」を分けて扱う。
- 特例：外国人学生の特例、編入・転学科に伴う個別認定等は、今回の判定対象から除外する。
- 履修データ：アカウントに紐づくアプリ保存済みのダミー履修データを読み出す。教務システムからの取得は将来対応とし、今回は実装しない。
- 利用形態：ローカル開発専用の固定デモアカウント。実アカウントの登録・ログインと、認証なしでの外部公開は今回の対象外。
- 用語の定義は[CONTEXT.md](CONTEXT.md)を参照。

判定設計の基準資料は、リポジトリ内の[2024年度学生便覧・知能情報コース](docs/kogaku_chinot_y24.pdf)。
便覧の数値・科目条件と未確定事項は[2024年度の卒業要件判定設計](docs/graduation-rules-2024.md)に整理する。
公式の2024年度共通教育科目表も確認し、科目・出典を要件JSONへ登録済み。実績・見込み判定と将来計画の保存をローカルデモで利用できます。特別講義Ⅴ・Ⅵの単位数など原本で未確認の情報は、推測せず「要確認」として扱います。

## 技術スタック

- Ruby 3.4 / Rails 8
- Hotwire (Turbo + Stimulus) / Importmap / Propshaft
- Tailwind CSS (tailwindcss-rails)
- PostgreSQL 17
- Docker Compose

## セットアップ

Docker DesktopまたはColimaでDockerが起動していれば、以下で開発環境が立ち上がります。

```bash
git clone git@github.com:ore-orange/graduation-requirements-checker.git
cd graduation-requirements-checker

docker compose build
# gem はコンテナ側のボリュームに入るので、build だけでは更新されない
docker compose run --rm web bundle install
docker compose run --rm web bin/rails db:prepare
docker compose run --rm web bin/rails db:seed
docker compose up

# git hooks を有効化（pre-commit で bin/ci が走るようになる。初回だけ）
git config core.hooksPath .githooks
```

http://localhost:3000/demo を開くと、固定デモアカウントの判定画面が表示されます。既存環境でも新しいMigrationとseedを適用してください。

`db:seed` は学部・学科のマスタも作ります（デモデータとは別で、環境を問わず作られます）。**流さないと、講義登録の取り込みと絞り込みで学部・学科のプルダウンが空になります。**

`bin/setup` を使う場合は `git config core.hooksPath` も自動で設定されます。

```bash
docker compose exec web bin/setup --skip-server
```

### ローカルデモ

```bash
docker compose exec web bin/rails db:migrate
docker compose exec web bin/rails db:seed
```

- 修得済み・履修登録済み・履修中のデータは架空のサンプルです。読み取り専用で、実績と見込みを分けて表示します。
- 科目名・番号・区分から将来科目を探し、追加・削除できます。操作ごとにDBへ保存され、再訪時にも復元されます。seedの再実行で保存済み計画は消しません。
- 卒業研究Ⅰ・ⅡとセミナーⅠ・Ⅱを追加すると、見込み判定の充足への変化を確認できます。未確認の特別講義Ⅴ等を選ぶと「要確認」を確認できます。
- デモは開発・テスト環境、ローカルホストでのみ利用できます。本番・非ローカルからのデータ閲覧や変更は404になります。
- ComposeのWeb公開先は`127.0.0.1:3000`に限定しています。`LOCAL_DEMO_PROXY=1`は、このloopback公開を前提にしたDockerプロキシ許可です。外部公開する構成へ流用しないでください。

### 講義登録（授業時間配当表の取り込み）

> **現時点では、工学部の授業時間配当表（`kogaku_chino_course_1.pdf` など）にのみ対応しています。** 表の幅が違うPDFは、見出しの位置から列を合わせて読みます。
> 共通教育・他の学部のPDFは、表の列の位置や講義コードの形式が違うため、正しく読み取れません。

ローカルのアプリ上部の「講義登録」タブから、授業時間配当表PDFを取り込める（開発・テスト環境のみ。認証がないため）。
Ghostscript が必要なので、初回は `docker compose build web && docker compose up -d` でイメージを作り直す。

1. 「講義を追加」を押し、年度・開講学部・開講学科・学期（前期・後期）を選んでPDFをアップロードする（ドラッグ&ドロップも可）。4つとも必須で、どれが欠けても取り込みを始めない。年度は暦の年ではなく年度なので、2026年度の後期も「2026年度」を選ぶ。PDF自体は保存せず、読み取った行だけを一時テーブルに置く。
2. 表示された行を**必ずPDFと見比べ**、違う値は直す。行の右端の「確認済み」にチェックを入れ、画面下の「チェックした行を確認済みにして更新」を押す。読み取りに自信のない行には理由が出る。見出しのチェックで、このページの全行を一度に入れ外しできる。チェックはページを移動しても（このブラウザの中で）覚えていて、更新するとほかのページ分もまとめて反映する。入力した値は覚えないので、直したページで更新する。値に問題があって確認済みにできない行があると、その行のあるページへ移動して赤く表示する。
3. 科目番号と科目名がどちらも同じ講義が既に登録されている行（「被り」）にだけ、科目名の下に小さな選択が出る。同じ講義が1件で単位も同じなら「既存の講義として扱う」が最初から選ばれており、違うときだけ「別の講義として登録」に変える。同じ講義が複数ある、または単位が違う行は、選ぶまで確認済みにできない。
4. すべて確認済みにすると保存内容（新規・更新・変更なしの件数）が出る。画面下の「保存する」を押すと `courses` と `course_offerings` に入る。

エラーが1件でもあると何も保存しない。同じPDFを再度取り込んでも、開講情報は年度・学期・講義コードで照合するので重複しない。年度が違えば別の行として増えるので、来年取り込み直しても去年の曜日・時限は残る。
**講義コードは必須**で、空の行は確認済みにできない（読み取れなかった行や手で足した行は、PDFを見て埋める）。
科目番号・科目名・単位は `courses`、年度・開講学科・必修/選択・受講年次・曜日・時限・学期などは `course_offerings` に入る。

保存済みの講義は、講義登録の画面の検索バーで **年度・開講学部・開講学科・科目番号・講義コード・科目名** で絞り込める。科目番号・講義コード・科目名は部分一致で、大文字小文字は区別しない。条件はURLに残るので、そのまま共有できる。

## DB設計・Supabase

- [DB設計・関連・未確定仕様](docs/database-design.md)
- [Supabase接続と承認後の反映手順](docs/supabase.md)
- [卒業要件JSON・Repositoryの契約](config/curricula/README.md)

業務テーブルはRails Migrationで管理します。要件JSONには一次資料由来の科目を登録し、開発・テストの明示的なseedで科目マスタと架空の履修データを作成します。実際の学生データや教務システム連携は含みません。
本番のSolid Cache / Queue / Cableの単一DB集約は承認待ちで、本番反映は未実施です。
接続変数の一覧は`.env.example`を参照してください（Railsによる自動読み込みはありません）。

## 開発の流れ

```
ブランチを切る → 実装 → 動作確認 → テストと RuboCop を通す → コミット → プッシュして PR
```

### 1. ブランチを切る

`main` への直 push は禁止しています。必ずブランチを切ってください。ブランチ名は自由です。

```bash
git switch -c graduation-requirement-model
```

### 2. 実装する

### 3. 動作確認する

http://localhost:3000 を開いて、実際に触って確認します。

### 4. テストと RuboCop を通す

**コミットする前に必ず通してください。**

```bash
docker compose exec web bin/ci
```

RuboCop の違反はほとんど自動修正できます。

```bash
docker compose exec web bin/rubocop -a
```

### 5. コミットする

```bash
git add -A
git commit -m "feat: 卒業要件の判定ロジックを追加する"
```

コミット時に pre-commit フックが `bin/ci` を自動で実行します。4 を飛ばしてもここで止まるので、通らないとコミットできません。

### 6. プッシュして PR を出す

```bash
git push -u origin graduation-requirement-model
```

PR を作るとテンプレートが展開されます。関連 issue と動作確認は埋めてください。マージには CI 5ジョブすべての通過が必要です。承認数は 0 なので自分でマージできます。

### コミットメッセージ

Conventional Commits の prefix + 日本語の本文。

| prefix | 用途 |
|---|---|
| `feat:` | 機能追加 |
| `fix:` | バグ修正 |
| `refactor:` | 挙動を変えない改善 |
| `test:` | テストの追加・修正 |
| `docs:` | ドキュメント |
| `chore:` | 雑務（依存更新は `chore(deps):`） |

例: `feat: 卒業要件の判定ロジックを追加する`

## CI

`.github/workflows/ci.yml` が main への push と Pull Request で動きます。

| ジョブ | 内容 |
|---|---|
| `scan_ruby` | brakeman（Rails の脆弱性静的解析）+ bundler-audit（gem の既知脆弱性） |
| `scan_js` | importmap audit（JS 依存の脆弱性） |
| `lint` | RuboCop + yamlfmt |
| `test` | `bin/rails test` |
| `system-test` | `bin/rails test:system`（失敗時はスクリーンショットを artifact に保存） |

### bin/ci — ローカルで全チェックを一括実行

Rails 8.1 の `ActiveSupport::ContinuousIntegration` を使っています。
実行内容は `config/ci.rb` に定義されていて、1コマンドで全部回せます（約5秒）。

```bash
docker compose exec web bin/ci
```

```
✅ Style: Ruby                           (bin/rubocop)
✅ Style: YAML                           (yamlfmt config/locales)
✅ Security: Gem audit                   (bin/bundler-audit)
✅ Security: Importmap vulnerability audit
✅ Security: Brakeman code analysis
✅ Tests: Rails                          (bin/rails test)
```

- web コンテナが起動していないと止まります。先に `docker compose up -d` してください。
- どうしても今だけ飛ばしたい場合は `git commit --no-verify`。

### system test

ローカルでも動きます。`bin/ci` では起動が遅いため既定では実行しません。

```bash
docker compose exec -e RAILS_ENV=test web bin/rails test:system
```

> Google Chrome は Linux arm64 版が無いため、コンテナ内では **Chromium** を使っています。
> CI の runner には本物の Chrome があるので、`test/application_system_test_case.rb` が自動的に切り替えます。

> **マイグレーションを追加したら `db/schema.rb` を必ずコミットしてください。** CI の `db:test:prepare` が schema.rb を読むため、
> 入れ忘れるとテストジョブが落ちます。

## よく使うコマンド

```bash
docker compose up              # 起動（-d でバックグラウンド）
docker compose down            # 停止
docker compose logs -f web     # ログを見る

# Rails コマンドは web コンテナ内で実行する
docker compose exec web bin/rails console
docker compose exec web bin/rails generate model Course name:string
docker compose exec web bin/rails db:migrate
docker compose exec web bin/rails test
docker compose exec web bash   # シェルに入る
```

## コード規約

`.rubocop.yml` でチーム共通のスタイルを定めています。主な点:

- 文字列リテラルは**シングルクオート**（`Style/StringLiterals: single_quotes`）
- **日本語コメント OK**（`Style/AsciiComments` 無効）
- 各ファイル先頭に `# frozen_string_literal: true`
- シンボル配列は `%i[]`、文字列配列は `%w[]`
- `Metrics/AbcSize` は 30、`Metrics/MethodLength` は 20 まで緩和

Rails 既定とは異なるので、エディタの自動整形任せにせず `bin/rubocop -a` で合わせてください。

## Gem を追加したとき

`Gemfile` を編集したら、コンテナ内で bundle install して Gemfile.lock を更新します。
gem はコンテナ側のボリュームに入るので、ホストで実行しても反映されません。

```bash
docker compose exec web bundle install
docker compose restart web
```

## Dependabot

- bundler は毎日チェックし、**1つの PR にまとめる**（グループ化）
- リリースから **7日間は様子見**（`cooldown`）してから PR を作る
- ただし **`brakeman` は例外** — セキュリティスキャナなので待たずに単独で更新する

## 困ったとき

- **`server is already running` と出る** → `tmp/pids/server.pid` を消すのは entrypoint が自動でやります。それでも出る場合は `docker compose down` してから起動。
- **DB に繋がらない** → `docker compose logs db` を確認。DB を作り直すなら `docker compose down -v`（**データが消えます**）してから `db:prepare`。
- **`LoadError: cannot load such file -- /app/rakefile` が出る** → git のブランチ切り替えやリベースでファイルが一斉に書き換わった直後に、
  Docker のファイル共有キャッシュが不整合を起こすことがあります。`docker compose restart web` で直ります。
- **`Could not find <gem>-x.y.z in locally installed gems (Bundler::GemNotFound)` で起動しない** → `Gemfile` が変わったブランチをチェックアウトすると出ます。
  `compose.yml` が `bundle_data` ボリュームを `/usr/local/bundle` にマウントしているため、イメージを作り直してもボリューム内の古い gem が使われます。
  `docker compose run --rm web bundle install` で入れ直してください。
- **Gemfile.lock がコンフリクトした** → lock は手で直さず、Gemfile を解決してから `docker compose exec web bundle install` で再生成する。
- **消したはずの Tailwind クラスが残っている** → `tailwindcss:watch` は増分ビルドのため残り続けます。
  `docker compose exec web bin/rails tailwindcss:build` でフルビルドしてください（本番は常にフルビルドなので影響しません）。
