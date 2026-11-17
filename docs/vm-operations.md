# 学科サーバーVMの運用手順

VM の再起動、DB マイグレーション、手動デプロイなど、VM 上で行う操作のコマンドと手順をまとめる。
構成の背景は [deploy-runner.md](deploy-runner.md)、バックアップの詳細は [db-backup.md](db-backup.md) を参照。

## 前提

- アプリは `/opt/grc/compose.prod.yml` の Docker Compose で動く。`web`(Rails)と `db`(Postgres 17)の2つ。
- 以降のコマンドは VM 上で、次の変数を定義してから実行する(シェルを開き直すたびに必要)。

```bash
compose="docker compose -f /opt/grc/compose.prod.yml --project-directory /opt/grc"
```

- `sudo` が必要な操作が多い。`docker` グループに入っていても、`/opt/grc/.env` などは root しか読めない。

| 場所 | 中身 |
|---|---|
| `/opt/grc/compose.prod.yml` | compose 定義(リポジトリの `deploy/compose.prod.yml` が正本) |
| `/opt/grc/.env` | 秘密情報(`DB_PASSWORD` など)。Git には入れない |
| `/var/backups/grc/` | DB のダンプ(14日分、root のみ読める) |
| `/var/lib/grc/deployed_sha` | 最後にデプロイした SHA |

---

## 1. VM を再起動するとき

### 1-1. 再起動前(任意だが推奨)

再起動で DB コンテナが止まるので、念のためバックアップを取る。

```bash
sudo systemctl start grc-backup.service
sudo journalctl -u grc-backup.service -n 5      # "backup ok: ..." が出ること
```

デプロイ中(GitHub Actions が動いている最中)は再起動しない。`grc-deploy` が途中で止まる。

### 1-2. 再起動

```bash
sudo reboot
```

Docker が止まるとき、コンテナは停止シグナルを受けて終了する。Postgres は正常終了するのでデータは壊れない。

### 1-3. 再起動後の確認

`web` と `db` は `restart: unless-stopped` なので、Docker が起動すれば自動で戻る。次の順に確認する。

```bash
# (1) Docker 自体が自動起動する設定か
systemctl is-enabled docker                      # enabled
systemctl is-active docker                       # active

# (2) コンテナ
sudo $compose ps                                 # web と db が Up、db は healthy

# (3) アプリが応答するか
curl -fsS http://127.0.0.1:3000/up               # 200 が返る

# (4) デプロイ用 runner
systemctl list-units 'actions.runner.*'          # active (running)
ps -eo user,pid,cmd | grep Runner.Listener       # 1列目が grc-runner

# (5) バックアップのタイマー
systemctl list-timers grc-backup.timer           # NEXT に次の 03:30 が出る
```

`web` は `db` が healthy になってから起動する(`depends_on`)。起動直後は数十秒かかることがある。

### 1-4. うまくいかないとき

| 症状 | 確認・対処 |
|---|---|
| コンテナが無い・止まっている | `sudo systemctl status docker` で Docker を確認。その後 `sudo $compose up -d` |
| `web` が再起動を繰り返す | `sudo $compose logs --tail 100 web`。`.env` の値やDB接続のエラーが多い |
| `db` が healthy にならない | `sudo $compose logs --tail 100 db`。`/opt/grc/certs` の権限(Postgres の SSL 鍵)を疑う |
| runner が落ちている | `journalctl -u 'actions.runner.*' -n 50`。復旧するまで次のデプロイは動かない |
| `/up` が返らない | まず `web` のログを見る。`curl` は VM 自身から `127.0.0.1:3000` に対して行う(外には公開していない) |

---

## 2. DB マイグレーション

### 2-1. 通常は自動で行われる

main に push すると CI → Deploy が動き、VM の `grc-deploy` が次の順で実行する。**手動での作業は要らない。**

```
pull → db を起動 → grc-backup(直前バックアップ) → db:migrate → up -d → ヘルスチェック
```

マイグレーションの前に必ずバックアップを取るので、失敗しても戻せる。
結果は GitHub の Actions の Deploy ジョブで確認する。VM 側では次で確認できる。

```bash
cat /var/lib/grc/deployed_sha                    # 最後にデプロイした SHA
sudo $compose exec web ./bin/rails db:migrate:status | tail -n 10
```

`db:migrate:status` で `down` が残っていなければ、全て適用済み。

### 2-2. 手動でマイグレーションするとき

自動デプロイが使えない場合(runner が落ちている、緊急対応など)に行う。

```bash
# (1) 直前バックアップ
sudo systemctl start grc-backup.service
sudo journalctl -u grc-backup.service -n 5       # "backup ok: ..."

# (2) デプロイ済みのイメージで実行する(IMAGE_TAG を揃える)
export IMAGE_TAG=$(cat /var/lib/grc/deployed_sha)
sudo --preserve-env=IMAGE_TAG $compose pull
sudo --preserve-env=IMAGE_TAG $compose run --rm web ./bin/rails db:migrate

# (3) 状態の確認
sudo --preserve-env=IMAGE_TAG $compose run --rm web ./bin/rails db:migrate:status | tail -n 10
```

新しいマイグレーションを含むコミットを手動で出したいときは、(2) を手作業で組むより、
次の「手動デプロイ」を使う。マイグレーションまで一緒に行われる。

### 2-3. マイグレーションに失敗したら

1. **慌てて再実行しない。** まずエラー内容を読む(`grc-deploy` の出力、または上の `db:migrate` の出力)。
2. `db:migrate` はトランザクション内で実行されるので、途中で失敗した分は自動で巻き戻る。
   `db:migrate:status` で、どこまで適用されたかを確認する。
3. 直前の状態に戻したいだけなら、`up -d` していなければ `web` は古いイメージのまま動いている。
   `grc-deploy` は `db:migrate` が失敗するとそこで止まる(`up -d` まで進まない)ので、古いアプリが動き続ける。
4. データが壊れた・戻せないときだけ、バックアップから復元する(下記)。

### 2-4. バックアップからの復元(最終手段)

本番を上書きする操作。復元前の状態も失われるので、先にもう一度バックアップを取っておく。

```bash
sudo systemctl start grc-backup.service          # 今の状態も残す
sudo sh -c 'ls -lt /var/backups/grc | head'      # 戻したいダンプを選ぶ

sudo $compose stop web
sudo cat /var/backups/grc/<ファイル名>.dump \
  | sudo $compose exec -T db pg_restore -U app -d app_production --clean --if-exists
sudo $compose start web
curl -fsS http://127.0.0.1:3000/up
```

復元したら、アプリのコード(イメージ)もそのダンプの時点に合っているか確認する。
スキーマが古いダンプに新しいコードを合わせると動かない。必要なら 3. の手動デプロイで SHA を戻す。
復元のテスト(本番に触れない方法)は [db-backup.md](db-backup.md) の「復元テスト」にある。

---

## 3. 手動デプロイ

GitHub Actions を使わず、VM から直接デプロイする。ロールバックにも使える。

```bash
sudo /usr/local/bin/grc-deploy <コミットSHA(40桁)>
```

- 実行内容は 2-1 の流れと同じ(pull → バックアップ → migrate → up → ヘルスチェック)。
- SHA は 40桁の16進。短縮 SHA は受け付けない。
- 同時実行はロックされる(`deploy already running` で終了コード 3)。
- ヘルスチェックに失敗すると、`web` のログを出して終了コード 1。
- イメージは `ghcr.io` に `:<SHA>` のタグで保存されているものだけ使える(main に入ったコミット)。

**注意:** 古い SHA に戻しても、すでに適用したマイグレーションは巻き戻らない。
コードが新しいスキーマに対応していない場合は、まず `db:rollback`(下記)か復元が必要。

```bash
# 直前のマイグレーション1つを戻す(down が書かれているものだけ)
export IMAGE_TAG=$(cat /var/lib/grc/deployed_sha)
sudo --preserve-env=IMAGE_TAG $compose run --rm web ./bin/rails db:rollback STEP=1
```

データを消す変更は `db:rollback` では戻らないことがある。迷ったらバックアップから復元する。

---

## 4. 設定を変更したとき

| 変更したもの | 反映の手順 |
|---|---|
| `deploy/compose.prod.yml` | `sudo install -m 644 deploy/compose.prod.yml /opt/grc/compose.prod.yml` のあと `sudo $compose up -d`。ワークフローは自動配置しない |
| `/opt/grc/.env` | `sudo $compose up -d --force-recreate web`。`env_file` はコンテナ作成時にしか読まれないので、`restart` では反映されない |
| `deploy/grc-deploy` | `sudo install -o root -g root -m 755 deploy/grc-deploy /usr/local/bin/grc-deploy`(自動では反映されない) |
| `deploy/grc-backup*` | [db-backup.md](db-backup.md) の「VM への配置」 |

`/opt/grc/certs` の権限は変えない(Postgres の SSL 鍵)。

---

## 5. 日常の確認コマンド

```bash
sudo $compose ps                                 # コンテナの状態
sudo $compose logs -f --tail 100 web             # web のログ(Ctrl+C で抜ける)
sudo $compose logs --tail 100 db                 # db のログ
sudo $compose restart web                        # web だけ再起動(.env の変更は反映されない)
curl -fsS http://127.0.0.1:3000/up               # ヘルスチェック
cat /var/lib/grc/deployed_sha                    # デプロイ済みの SHA
sudo sh -c 'ls -lt /var/backups/grc | head'      # バックアップの一覧
systemctl list-timers grc-backup.timer           # 次のバックアップ予定
```

### やってはいけないこと

- `docker compose down -v`: `-v` を付けると `pgdata` ボリューム(本番 DB)が消える。止めるだけなら `stop`、再作成なら `up -d --force-recreate` を使う。
- `/var/backups/grc` の手動削除: 古いダンプは `grc-backup` が14日で自動削除する。
- `.env` や `DB_PASSWORD` をチャット・Issue・ログに貼ること。このリポジトリは公開されている。
