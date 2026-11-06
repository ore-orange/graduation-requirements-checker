# PR58 レビュー指摘事項

- 対象: `feat: 学科サーバーVMへDocker Composeでデプロイ（CD付き）できるようにする`
- ブランチ: `feat/vm-compose-deploy` → `main`
- 方法: コードの読み取りのみ（実行はしていない）

## 変更ファイル

| ファイル | 変更 |
|---|---|
| `.github/workflows/deploy.yml` | +70（新規） |
| `config/environments/production.rb` | +3 −3 |
| `deploy/Caddyfile` | +5（新規） |
| `deploy/compose.prod.yml` | +36（新規） |

## 指摘一覧

| 重要度 | 内容 | 場所 |
|---|---|---|
| 重大 | フォークPR経由でself-hostedランナーが任意コードを実行しうる | `deploy.yml:3-7` |
| 中 | Postgresの鍵ファイルの所有者・権限で起動に失敗しうる | `compose.prod.yml:27-28` |
| 中 | `DB_PASSWORD` と `APP_DATABASE_PASSWORD` の変数名が食い違う | `compose.prod.yml` / `config/database.yml` |
| 軽微 | GHCRのpull認証がない | `deploy.yml` |
| 軽微 | `ALLOWED_HOSTS` 未設定で起動時エラー | `production.rb:84` |

## 1. 【重大】フォークPR経由でVM上のコード実行を許してしまう

**場所**: `.github/workflows/deploy.yml` 3〜7行目

**問題**
- リポジトリは公開で、`ci.yml` は `pull_request` でも走る。
- `workflow_run` の `branches: [ main ]` はヘッドブランチ名で絞り込む。
- 第三者がフォークの `main` ブランチからPRを出し、CIが成功すると、フォーク側のコミット（`head_sha`）がビルドされ、self-hostedランナーでデプロイされる。
- VM上で任意コードを実行され、DBのパスワードなども読まれかねない。

**修正案**: `build` と `deploy` の両ジョブに条件を足す。`deploy` は現状 `needs: build` に頼っているだけなので、`if` を付ける。

```yaml
if: >
  github.event.workflow_run.conclusion == 'success' &&
  github.event.workflow_run.event == 'push' &&
  github.event.workflow_run.head_repository.full_name == github.repository
```

## 2. 【中】Postgresの鍵ファイルで起動に失敗しうる

**場所**: `deploy/compose.prod.yml` 27〜28行目

**問題**
- `./certs:/certs:ro` でマウントした `server.key` は、所有者がpostgresユーザー（Debian系イメージではuid 999）またはrootで、権限が `0600`（rootなら `0640`）でないとPostgresが起動を拒否する。
- `:ro` のため、コンテナ内で `chmod`・`chown` できない。

**修正案**: 証明書の配置手順（所有者・権限）をREADMEなどに書く。または、権限を整えるエントリポイントを用意する。

## 3. 【中】DBパスワードの変数名が食い違う

**場所**: `deploy/compose.prod.yml` と `config/database.yml`

**問題**
- Composeは `POSTGRES_PASSWORD: ${DB_PASSWORD}` を使う。
- `config/database.yml` のproductionは `APP_DATABASE_PASSWORD` を参照する。
- `DATABASE_URL` を使えばURLが優先されるため、実害は出にくい。ただし `/opt/grc/.env` に `DB_PASSWORD` とURL内のパスワードの両方が必要で、ズレると接続できない。
- `.env.example` にこの組み合わせの記載がない。

**修正案**: 変数名を揃えるか、`.env.example` に必要な項目と対応関係を書く。

## 4. 【軽微】GHCRのpull認証がない

**場所**: `.github/workflows/deploy.yml`

- パッケージがprivateなら、VM側で事前に `docker login ghcr.io` が必要。
- deploy.yml内には認証手順がない。

## 5. 【軽微】`ALLOWED_HOSTS` 未設定で起動時エラー

**場所**: `config/environments/production.rb` 84行目

- `ENV["ALLOWED_HOSTS"].split(",")` は未設定だと `nil.split` で例外になる。
- `/opt/grc/.env` に必須であることを、手順に明記する。

## 問題なしと確認した点

- `/up` は `force_ssl` のリダイレクト除外と `host_authorization` の除外の両方が設定済みで、ヘルスチェック（`http://127.0.0.1:3000/up`）は通る想定。
- `actions/checkout@v7` は既存の `ci.yml` も使っている。
- `docker compose run --rm web` は `depends_on` により `db` を自動起動し、healthyを待つ。
