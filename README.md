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
- **Gemfile.lock がコンフリクトした** → lock は手で直さず、Gemfile を解決してから `docker compose exec web bundle install` で再生成する。
- **消したはずの Tailwind クラスが残っている** → `tailwindcss:watch` は増分ビルドのため残り続けます。
  `docker compose exec web bin/rails tailwindcss:build` でフルビルドしてください（本番は常にフルビルドなので影響しません）。
