# graduation-requirements-checker

琉球大学の卒業要件チェッカー

## 技術スタック

- Ruby 3.4 / Rails 8
- Hotwire (Turbo + Stimulus) / Importmap / Propshaft
- Tailwind CSS (tailwindcss-rails)
- PostgreSQL 17
- Docker Compose

## セットアップ

Docker Desktop が動いていれば、以下だけで開発環境が立ち上がります。

```bash
git clone git@github.com:ore-orange/graduation-requirements-checker.git
cd graduation-requirements-checker

docker compose build
docker compose run --rm web bin/rails db:prepare
docker compose up

# git hooks を有効化（pre-commit で bin/ci が走るようになる。初回だけ）
git config core.hooksPath .githooks
```

http://localhost:3000 を開いて Rails の画面が出れば成功です。

`bin/setup` を使う場合は `git config core.hooksPath` も自動で設定されます。

```bash
docker compose exec web bin/setup --skip-server
```

## CI

`.github/workflows/ci.yml`（Rails 8 の生成物）が main への push と Pull Request で動きます。

| ジョブ | 内容 |
|---|---|
| `scan_ruby` | brakeman（Rails の脆弱性静的解析）+ bundler-audit（gem の既知脆弱性） |
| `scan_js` | importmap audit（JS 依存の脆弱性） |
| `lint` | RuboCop（rails-omakase ルール） |
| `test` | `bin/rails test` |
| `system-test` | `bin/rails test:system`（失敗時はスクリーンショットを artifact に保存） |

### bin/ci — ローカルで全チェックを一括実行

`grade_review_tool` と同じく Rails 8.1 の `ActiveSupport::ContinuousIntegration` を使っています。
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

### pre-commit フック

`.githooks/pre-commit` がコミット前に `bin/ci` を実行します。落ちるとコミットできません。

```bash
git config core.hooksPath .githooks   # 初回だけ（bin/setup でも設定されます）
```

- web コンテナが起動していないと止まります。先に `docker compose up -d` してください。
- どうしても今だけ飛ばしたい場合は `git commit --no-verify`。

> **注意: system test はローカルでは動きません。** `Dockerfile.dev` に Chrome を入れていないため、
> `test/system` にテストを書くと手元では失敗します（CI の runner には Chrome があるので CI では通ります）。
> ローカルでも動かしたくなったら Chrome + chromedriver を `Dockerfile.dev` に追加してください。

> **マイグレーションを追加したら `db/schema.rb` を必ずコミットしてください。** CI の `db:test:prepare` が schema.rb を読むため、
> 入れ忘れるとテストジョブが落ちます。

## 開発フロー

`grade_review_tool` と同じ規約に揃えています。

### ブランチ名

```
<type>/<issue番号>/<説明>/<自分の名前>
```

例: `feat/12/graduation-requirement-model/touyama`、`refactor/34/extract-credit-calculator/hikaru`

### コミットメッセージ

Conventional Commits の prefix + 日本語の本文。`grade_review_tool` で使われている種別:

| prefix | 用途 |
|---|---|
| `feat:` | 機能追加 |
| `fix:` | バグ修正 |
| `refactor:` | 挙動を変えない改善 |
| `test:` | テストの追加・修正 |
| `docs:` | ドキュメント |
| `chore:` | 雑務（依存更新は `chore(deps):`） |

例: `feat: 卒業要件の判定ロジックを追加する`

### PR

- `main` への直 push は禁止。必ず PR を経由します。
- PR を作ると `.github/pull_request_template.md` が展開されます。関連 issue と動作確認は埋めてください。
- マージには CI の5ジョブすべての通過が必要です。
- マージ方式は **merge commit**（`grade_review_tool` と同じ）。

### Dependabot

`grade_review_tool` と同じ設定にしています。

- bundler は毎日チェックし、**1つの PR にまとめる**（グループ化）
- リリースから **7日間は様子見**（`cooldown`）してから PR を作る
- ただし **`brakeman` は例外** — セキュリティスキャナなので待たずに単独で更新する

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

`.rubocop.yml` は **`grade_review_tool` と同じルール**を流用しています（Slim 未使用のため `rubocop-slim` のみ除外）。
チーム内でプロジェクトをまたいでもコードの書き方が揃うようにする狙いです。主な点:

- 文字列リテラルは**シングルクオート**（`Style/StringLiterals: single_quotes`）
- **日本語コメント OK**（`Style/AsciiComments` 無効）
- 各ファイル先頭に `# frozen_string_literal: true`
- シンボル配列は `%i[]`、文字列配列は `%w[]`
- `Metrics/AbcSize` は 30、`Metrics/MethodLength` は 20 まで緩和

Rails 既定の omakase とは異なるので、エディタの自動整形任せにせず `bin/rubocop -a` で合わせてください。

```bash
docker compose exec web bin/rubocop      # チェック
docker compose exec web bin/rubocop -a   # 自動修正
```

## Gem を追加したとき

`Gemfile` を編集したら、コンテナ内で bundle install して Gemfile.lock を更新します。

```bash
docker compose exec web bundle install
docker compose restart web
```

## 困ったとき

- **`server is already running` と出る** → `tmp/pids/server.pid` を消すのは entrypoint が自動でやります。それでも出る場合は `docker compose down` してから起動。
- **DB に繋がらない** → `docker compose logs db` を確認。DB を作り直すなら `docker compose down -v`（**データが消えます**）してから `db:prepare`。
- **`LoadError: cannot load such file -- /app/rakefile` が出る** → git のブランチ切り替えやリベースでファイルが一斉に書き換わった直後に、
  Docker のファイル共有キャッシュが不整合を起こすことがあります。`docker compose restart web` で直ります。
- **Gemfile.lock がコンフリクトした** → lock は手で直さず、Gemfile を解決してから `docker compose exec web bundle install` で再生成する。

## 構成メモ

- `Dockerfile.dev` / `compose.yml` … 開発環境。`Dockerfile`（Rails 生成）は本番用なので開発では使いません。
- gem は名前付きボリューム `bundle_data` に入ります。ホスト側には入らないので `bundle install` は必ずコンテナ内で。
- 起動は `bin/dev`（`Procfile.dev`）で、`rails server` と `tailwindcss:watch` を並行実行します。`foreman` は `Dockerfile.dev` に入れています。
- `Procfile.dev` の `rails server` には `-b 0.0.0.0` が必須です（付けないとコンテナ外から繋がりません）。
- DB 接続情報は `config/database.yml` が環境変数（`DATABASE_HOST` / `DATABASE_USER` / `DATABASE_PASSWORD`）を読む形にしてあり、値は `compose.yml` で与えています。
