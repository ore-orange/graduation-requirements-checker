# 本番DBのバックアップ

学科サーバーVMの本番DB(db コンテナの `app_production`)を、`pg_dump` で毎日保存する。

## 全体像

```
systemd timer(毎日 3:30)  ─┐
grc-deploy(db:migrate の前) ─┴─ /usr/local/bin/grc-backup(root で実行)
                                  ├─ db コンテナ内で pg_dump → /var/backups/grc/app_production_<日時>.dump
                                  ├─ pg_restore -l でダンプとして読めるか検証
                                  └─ 14日より古いダンプを削除
```

- ダンプは成績データを含むので、`umask 077` で root 以外は読めない。
- 失敗した途中のファイルは `.tmp` のまま残り、正常なダンプと区別できる。
- `grc-runner` には権限を渡さない。`grc-deploy` から呼ばれるときも、root として動く。

| ファイル(リポジトリ) | VM の配置先 |
|---|---|
| `deploy/grc-backup` | `/usr/local/bin/grc-backup` |
| `deploy/grc-backup.service` | `/etc/systemd/system/grc-backup.service` |
| `deploy/grc-backup.timer` | `/etc/systemd/system/grc-backup.timer` |

## VM への配置

リポジトリが正本。VM のファイルは直接編集せず、変更したら同じコマンドで入れ直す。

```bash
sudo install -o root -g root -m 755 deploy/grc-backup /usr/local/bin/grc-backup
sudo install -o root -g root -m 644 deploy/grc-backup.service deploy/grc-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now grc-backup.timer
```

`grc-deploy` は `grc-backup` を呼ぶので、**`grc-backup` を先に入れてから** `grc-deploy` を入れ直す。

```bash
sudo install -o root -g root -m 755 deploy/grc-deploy /usr/local/bin/grc-deploy
```

## 動作確認

`grc-backup.service` は1回動いて終わるサービスなので、`status` が `inactive (dead)` でも正常。
動いているかは、timer の予定とダンプのファイルで判断する。

```bash
sudo systemctl start grc-backup.service           # 手動で1回実行
sudo journalctl -u grc-backup.service -n 20       # "backup ok: ..." が出ること(sudo が必要)
systemctl list-timers grc-backup.timer            # NEXT に次の 03:30 が出ること
sudo sh -c 'ls -lt /var/backups/grc | head'       # ダンプが増えていること
```

`/var/backups/grc` は root しか読めないので、`*` を使うときは `sudo sh -c '...'` の中に書く。

## 復元テスト

本番には触れず、別の DB(`restore_test`)に戻して件数を比べる。定期的に一度は行う。

```bash
compose="docker compose -f /opt/grc/compose.prod.yml --project-directory /opt/grc"

# 比較のため、今の状態でバックアップを取り直す
sudo systemctl start grc-backup.service
f=$(sudo sh -c 'ls -t /var/backups/grc/app_production_*.dump | head -1')

sudo $compose exec -T db createdb -U app restore_test
sudo cat "$f" | sudo $compose exec -T db pg_restore -U app -d restore_test --no-owner

count_sql="SELECT table_name, (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text::int AS rows FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name;"
sudo $compose exec -T db psql -U app -d app_production -At -c "$count_sql" > /tmp/count_prod.txt
sudo $compose exec -T db psql -U app -d restore_test   -At -c "$count_sql" > /tmp/count_restore.txt
diff /tmp/count_prod.txt /tmp/count_restore.txt && echo "一致しました"
```

片付け。`dropdb` の対象が `restore_test` であることを必ず確かめる。

```bash
sudo $compose exec -T db dropdb -U app restore_test
rm /tmp/count_prod.txt /tmp/count_restore.txt
sudo $compose exec -T db psql -U app -d postgres -Atc 'SELECT datname FROM pg_database ORDER BY datname;'   # restore_test が無く、app_production があること
```

## 本番DBへの復元

本番を上書きする操作なので自動化しない。web を止めてから行う。

```bash
sudo $compose stop web
sudo cat /var/backups/grc/<ファイル名>.dump | sudo $compose exec -T db pg_restore -U app -d app_production --clean --if-exists
sudo $compose start web
curl -fsS http://127.0.0.1:3000/up
```

## 今後の検討事項

- **別の場所への転送**: いまはダンプが VM の中にしかなく、VM が壊れると一緒に失われる。転送先が決まったら、`grc-backup` の `mv` の後に `rsync` などを1行足す。ホスト名や認証情報はスクリプトに書かず、VM 側の SSH の設定などに置く(このリポジトリは公開)。
- **失敗の通知**: いまは失敗してもログに残るだけ。`grc-backup.service` に `OnFailure=` を足し、通知用のユニットを動かす。
