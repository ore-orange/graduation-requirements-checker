# Supabase接続準備（本番未反映）

SupabaseはPostgreSQLホスティングとしてのみ使用する。
Auth / Storage / RealtimeやSupabaseクライアントは導入していない。
**本番の接続・Migrationは未実行。実行にはユーザーの明示的な承認が必要。**

## 接続方式

公式: <https://supabase.com/docs/guides/database/connecting-to-postgres>

常駐RailsとMigrationには以下を使用する。

- IPv6対応（またはIPv4 add-onあり）: Direct、5432。
- IPv4のみ: Shared poolerのSession mode、5432。
- ホスト名・ユーザー名・リージョン等は推測せずDashboardのConnectからコピーする。
- Transaction mode（6543）は今回の標準にはしない。
  prepared statementsだけでなくセッション状態やMigrationのadvisory lockにも注意が必要。
  採用する場合は別途検証し、Railsのprepared_statementsをfalseにする。
  MigrationはDirectまたはSession modeで実行する。

URL例（秘密値を含まない説明用）:

```text
postgresql://postgres:<URL_ENCODED_PASSWORD>@db.<PROJECT_REF>.supabase.co:5432/postgres
postgresql://postgres.<PROJECT_REF>:<URL_ENCODED_PASSWORD>@<POOLER_HOST>:5432/postgres
```

パスワード内の@、:、/等はURLエンコードする。
DBパスワードはAPI key / anon key / service_role keyとは別物。
URLや全ENVをログに出す、コマンドラインにURLを直書きする、チャットに貼る操作は避ける。

## 環境変数

デプロイ先のsecret管理機能で `DATABASE_URL` を登録する。
`DATABASE_SSLMODE`は既定でrequire（暗号化必須）。
サーバーの真正性検証にはverify-fullを推奨。
SupabaseのDatabase settingsから取得したルート証明書を配置し、
`DATABASE_SSLROOTCERT`にそのパスを設定する。
URLクエリのsslmodeは設定値より優先されるため、無効化を指定しない。
本番起動時に最終的なsslmodeを検査する。

ローカル環境は固定のgrc_development / grc_testを使用する。
URLを明示する場合はDEVELOPMENT_DATABASE_URL / TEST_DATABASE_URLを使える。
DATABASE_URLもRails標準として使えるが、開発/テストではローカルの固定DBしか許可しない。
.env.exampleは設定項目の例。dotenv未導入のためRailsは.envを自動読み込みしない。
既存Composeはローカル接続専用で、ホストのDATABASE_URLをwebへ自動転送しない。
本番を開発Composeで起動せず、本番用デプロイ環境を用意する。

## 要承認: Solid Cache / Queue / Cable

現在の本番設定は4つの物理DB（primary/cache/queue/cable）を想定している。
互換性維持のためまだ統合していない。現設定ではDATABASE_URLに加えて、
CACHE_DATABASE_URL / QUEUE_DATABASE_URL / CABLE_DATABASE_URLを別々のDBに設定する必要がある。
Supabaseの単一DBを4つの接続先へそのまま指定することは禁止（起動時も拒否）。
別々のschema.rbを同じDBにロードするとschema_migrations管理やロード処理が競合する。

**推奨案（承認待ち）:** 単一のSupabase DBにSolidのテーブルも集約する。
その場合は次をセットで変更する。

1. productionをprimaryのみにする。
2. Solid Cache / Queue / Cableの接続先をprimaryに統一する。
3. 既存のSolid schema定義から、破壊的なforce指定を使わないMigrationを作る。
4. schema.rbを再生成し、ローカルで補助テーブルとSolid各機能を検証する。
5. 上記4URL必須/共有DB拒否の安全検査を、承認済みの単一DB構成に合わせて更新する。

この作業が未承認のため、現在の設定をそのまま単一Supabase DBへデプロイしない。
Kamalのdeploy.ymlもテンプレートのままであり、ホスト/registry/secretの設定が別途必要。

## 成績データをData APIから公開しない

公式: <https://supabase.com/docs/guides/api/securing-your-api>

RailsからSQLで作ったpublicスキーマのテーブルも、プロジェクトの既定grant次第で
Data APIから公開され得る。SQL接続だけだから安全とは限らない。
今回のMigrationはRLS/policyを追加しない（Railsのschema.rbではRLSを完全に保存できない）。

**本番Migrationより前に、DashboardのData API設定でEnable Data APIをOFFにする。**
このアプリはData APIを利用しないため、公式が案内する無効化を基本とする。
プロジェクトを他アプリと共有して無効化できない場合は、このまま本番反映しない。
非公開schemaまたはRLSとgrantの設計、およびそれらを保持できるschema管理方法を先に確定する。
SQL接続ロールはサーバーだけで管理し、ブラウザへ渡さない。
別途、Rails側の認証・本人所有チェックを実装してから成績画面を公開する。

## 承認後の反映手順

**以下は手順の説明。今回実行していない。**

1. Solid構成を決め、上記の未完了事項を解消する。
2. 本番用プロジェクト/デプロイ先/接続方式を確認する。
3. Data API無効化と秘密管理を確認し、バックアップと復旧方法を用意する。
4. 承認を得たうえで、secretが注入された本番コンテナ内で接続先を読み取り確認する。

   ```bash
   RAILS_ENV=production bin/rails runner script/database_target.rb
   ```

   このスクリプトはhost/DB名とprimaryの実接続先/SSLを表示し、URL・パスワードは表示しない。
   結果を確認し、別プロジェクトでないこと、SSLがtrueであることを確認する。
   現時点ではSolid構成の安全検査があるため、単一DB設定では起動しない。

5. 同じ環境でMigrationの状態を確認する。

   ```bash
   RAILS_ENV=production bin/rails db:migrate:status:primary
   ```

6. **DB変更への明示的な承認後にのみ**適用する。
   現在の別DB構成で業務テーブルだけを適用する場合:

   ```bash
   RAILS_ENV=production bin/rails db:migrate:primary
   ```

   Solid集約が実装済みならprimaryだけの構成になり、通常のdb:migrateで全テーブルを適用する。
   既存DBにdb:schema:load / db:reset / db:dropを実行しない。
   SupabaseはDBが作成済みなので、本番でdb:createを実行しない。
   schemaロードを行い得るdb:prepareも、共有DBへの初回反映には使わない。
7. 状態・FK・テーブル数・公開設定を確認してからアプリを起動する。

## ローカル確認

```bash
docker compose exec -T web bin/rails runner script/database_target.rb
docker compose exec -T web bin/rails db:migrate
docker compose exec -T -e RAILS_ENV=test web bin/rails runner script/database_target.rb
docker compose exec -T -e RAILS_ENV=test web bin/rails db:migrate
docker compose exec -T web bin/rails test
docker compose exec -T web bin/rubocop
```

Migrationの前に対象がdb/grc_developmentまたはdb/grc_testであることを確認する。
