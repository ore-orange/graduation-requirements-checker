# 新しい学科サーバーVMへの移行手順

旧VMで動いているアプリと本番DBを、新しいVM(Ubuntu 26.04.1 LTS)へ移す手順。
日常の運用は [vm-operations.md](vm-operations.md)、構成の背景は [deploy-runner.md](deploy-runner.md)、
バックアップは [db-backup.md](db-backup.md) を参照。

このリポジトリは公開なので、ホスト名・IP・鍵・パスワードはここにもPR・Issueにも書かない。
以降は `<新VM>` `<旧VM>` `<HOST>` のように書く。

## 全体像

```
Phase A  新VMを用意する(旧VMは動かしたまま。ダウンタイムなし)
  0. SSHログインの確認と鍵の整理  1. OSの初期設定  2. Docker  3. /opt/grc の配置  4. Caddy  5. デプロイ用スクリプト・runner・バックアップ
Phase B  切り替える(ダウンタイムあり。目安 30分)
  6. 旧VMのwebを止めて、最終バックアップ  7. 新VMへDBを復元  8. 新VMでデプロイ  9. 接続先とrunnerを切り替える
Phase C  確認と後片付け
  10. 確認  11. 旧VMの停止と消去
```

移すもの:

| もの | 移し方 |
|---|---|
| アプリ本体 | 移さない。`ghcr.io` のイメージを新VMで pull する |
| 本番DB | `pg_dump` したダンプを `pg_restore` する(Docker のボリュームは**コピーしない**) |
| `/opt/grc/.env` | 旧VMからそのまま持ってくる(`SECRET_KEY_BASE` を変えるとログイン中のセッションが切れる) |
| `/opt/grc/certs` | 旧VMから持ってくる、または作り直す(3-3) |
| runner | 新VMで登録し直す。旧VMの runner は外す |
| バックアップ(`/var/backups/grc`) | 移さなくてよい。旧VMの最終ダンプだけ手元に残す |

## 事前に決めておくこと

- **切り替えの方法**: 同じホスト名のDNSを新VMに向けるのか、IPアドレスを入れ替えるのか。
- **TLS**: Let's Encrypt を使うなら、DNSが新VMを向いてからでないと証明書が取れない。
  DNSのTTLを事前に短くしておく。学内専用の名前なら `tls internal` を使う(`deploy/Caddyfile` のコメント参照)。
- **利用者への告知**: Phase B の間はアクセスできない。
- 新VMに旧VMと同じ**タイムゾーン**を設定する(バックアップは 03:30 に動く)。旧VMで `timedatectl` を確認。

---

## Phase A: 新VMを用意する

以降は特に書かない限り、新VM上で実行する。

### 0. SSHログインの確認と鍵の整理

前提: **手元のPCから新VMに SSH でログインできる**(自分の公開鍵が新VMの `~/.ssh/authorized_keys` に入っている)。
ここでは、ログインの確認と、`authorized_keys` に入っている鍵の整理だけを行う。

> `authorized_keys` に書くのは**公開鍵**(`.pub` の中身、`ssh-ed25519 AAAA...` の1行)だけ。
> 秘密鍵(`id_ed25519` など `.pub` が付かない方)は、どこにも貼らない・送らない。

#### 0-1. ログインと sudo を確認する

```bash
# 手元のPCで
ssh <ユーザー名>@<新VM>
```

入れたら、新VMで `sudo -v` が通ることも確かめる。ログインできないときは `ssh -v` の出力で切り分ける。

| 症状 | 確認 |
|---|---|
| `Connection refused` / `timed out` | 新VMで `systemctl status ssh`。`sudo ufw status` で 22 が許可されているか |
| `Permission denied (publickey)` | `~/.ssh` が 700、`authorized_keys` が 600 か。所有者が自分か(`ls -ld ~/.ssh ~/.ssh/authorized_keys`)。ユーザー名が合っているか |

#### 0-2. 新VMのホスト鍵を確認する

初回接続で「このホストを信頼するか」と聞かれたら、**新VMのコンソールか、すでに入れているセッションで**フィンガープリントを見て照合してから `yes` と答える。

```bash
# 新VMで
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

切り替え(9)で旧VMのホスト名やIPを新VMに引き継ぐと、手元のPCで `REMOTE HOST IDENTIFICATION HAS CHANGED` と出る。
新VMのホスト鍵だと確認できたら、古い記録を消して入り直す。

```bash
ssh-keygen -R <ホスト名またはIP>
```

#### 0-3. `authorized_keys` を整理する

旧VMから**丸ごとコピーしない**。移行を機に、今も必要な人の鍵だけにする。

```bash
# 新VMと旧VMで、それぞれフィンガープリントを一覧にして比べる
ssh-keygen -lf ~/.ssh/authorized_keys
```

- 旧VMの `authorized_keys` には、辞めた人・使わなくなったPC・自動化用の鍵が溜まっていることがある。
  誰の鍵か分からない行は入れない。末尾のコメントや、本人に確認したフィンガープリントで判断する。
- 自分の鍵かどうかは、手元のPCの `ssh-keygen -lf ~/.ssh/id_ed25519.pub` と一致するかで分かる。
- 古い鍵(RSA 2048 未満など)は、この機会に ed25519 に替えてもよい。

不要な行を消すときは、**今ログインに使っている鍵を消さない**。消す前にバックアップを取り、今のセッションは閉じない。

```bash
cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
nl ~/.ssh/authorized_keys             # 行番号つきで見る
sed -i '3d' ~/.ssh/authorized_keys    # 3行目を消す例
```

消したあと、**別の端末で**もう一度ログインできることを確認してから、元のセッションを閉じる。

#### 0-4. 他の人の鍵を追加する

本人から、公開鍵(`.pub` の1行)を受け取る。手元のPCから、ログインできる状態で追記する。

```bash
ssh-copy-id -i <受け取った.pubファイル> <ユーザー名>@<新VM>
# または
echo 'ssh-ed25519 AAAA... コメント' | ssh <ユーザー名>@<新VM> 'cat >> ~/.ssh/authorized_keys'
```

- 1鍵が1行になっているか、`wc -l ~/.ssh/authorized_keys` と `ssh-keygen -lf ~/.ssh/authorized_keys` で確認する。
- 各自のアカウントで入る場合は、ユーザーを分けて、それぞれの `~/.ssh/authorized_keys` に入れる(共有ユーザーに全員の鍵を入れるより追跡しやすい)。

#### 0-5. SSH サーバーの設定を確認する

```bash
sudo sshd -T | grep -E '^(pubkeyauthentication|passwordauthentication|permitrootlogin) '
```

`pubkeyauthentication yes` であること。パスワード認証と root ログインは、**1 の最後**で、鍵でのログインを確かめてから切る。

### 1. OSの初期設定

```bash
sudo apt update && sudo apt full-upgrade -y
sudo timedatectl set-timezone Asia/Tokyo        # 旧VMと同じ値にする
sudo apt install -y git curl unattended-upgrades
```

ファイアウォールは、SSH・HTTP・HTTPS だけ開ける。**SSH を許可してから有効にする**(順番を間違えると締め出される)。

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

`web` は `127.0.0.1:3000` にだけ公開しているので、外から直接は見えない。

SSH は、0 で整理した公開鍵でログインできることを**手元のPCから確認してから**、パスワード認証を切る。
先に切ると、鍵が通らなかったときにコンソールからしか入れなくなる。切った直後も、今のセッションは閉じずに、別の端末で鍵ログインをもう一度試す。

```bash
# 別の端末で鍵ログインできることを確認したあと
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh
```

Ubuntu 26.04 は、`sudo` や coreutils が Rust 実装(`sudo-rs`、`uutils`)になっていることがある。
手順の `sudo --preserve-env=...` や `grc-backup` の `date` / `find` / `du` が想定どおり動くか、
Phase A の最後(5-4)で必ず試す。

### 2. Docker

公式のaptリポジトリから入れる。

```bash
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

`apt-get update` が新しい Ubuntu のコードネームを見つけられないと、リポジトリが使えない。その場合は Ubuntu 標準のパッケージで代用する。

```bash
sudo apt-get install -y docker.io docker-compose-v2
```

```bash
sudo systemctl enable --now docker
sudo docker run --rm hello-world
sudo docker compose version
```

**自分のユーザーを `docker` グループに入れない。** `docker` グループは root 相当で、操作は `sudo` 経由で行う(runner の最小権限化と同じ考え方)。

### 3. `/opt/grc` を配置する

リポジトリを取得する。公開リポジトリなので認証は要らない。

```bash
git clone https://github.com/ore-orange/graduation-requirements-checker.git ~/grc-repo
cd ~/grc-repo
sudo install -d -m 755 /opt/grc
sudo install -m 644 deploy/compose.prod.yml /opt/grc/compose.prod.yml
```

#### 3-1. `.env`

旧VMの `/opt/grc/.env` を新VMに持ってくる。中身は秘密情報なので、チャット・Issue・ログに貼らない。
自分のPCを経由して送る。`scp -3` は手元のPCに保存せず中継するだけなので、手元にファイルは残らない。
**消すのは、旧VMと新VMのホームに作った中間コピー**(`~/grc.env`)。

```bash
# 手元のPCで(旧VMの .env は root 所有。先に旧VMで自分のホームにコピーして読めるようにする)
#   旧VM: sudo cp /opt/grc/.env ~/grc.env && sudo chown "$USER" ~/grc.env
scp -3 <旧VM>:~/grc.env <新VM>:~/grc.env
#   旧VM: rm ~/grc.env
```

```bash
# 新VMで
sudo install -o root -g root -m 600 ~/grc.env /opt/grc/.env
rm ~/grc.env
sudo ls -l /opt/grc/.env       # -rw------- root root
```

`.env` に入っている項目は `.env.example` の「学科サーバーVM」の欄を参照:
`RAILS_ENV` / `PORT` / `SECRET_KEY_BASE` / `DB_PASSWORD` / `ALLOWED_HOSTS` / `PUBLIC_DEMO`。

- `ALLOWED_HOSTS` に、**新しい接続先のホスト名**が含まれているか確認する。
- `DB_PASSWORD` は英数字のみ(URLに埋め込むため)。
- DB のパスワードは、新VMの `db` コンテナが**初回起動時に**この値で作る。復元(7)の前に決めておく。

#### 3-2. パッケージ(イメージ)の取得

```bash
sudo docker pull ghcr.io/ore-orange/graduation-requirements-checker:latest
```

`denied` と出る場合はイメージが非公開。GitHub の Personal Access Token(`read:packages` のみ)で
`sudo docker login ghcr.io -u <GitHubユーザー名>` する。トークンはシェルの履歴に残さない(標準入力から渡す)。

#### 3-3. DB の SSL 証明書

本番は DB 接続に SSL が必須(`config/initializers/database_safety.rb`)。`db` コンテナは `/opt/grc/certs` の自己署名証明書を使う。

**方法1: 旧VMのものをそのまま持ってくる(おすすめ)。** 所有者・権限を保ったまま移す。

```bash
# 旧VM
sudo tar -C /opt/grc -cpf ~/certs.tar certs && sudo chown "$USER" ~/certs.tar
# 手元のPC
scp -3 <旧VM>:~/certs.tar <新VM>:~/certs.tar
# 新VM
sudo tar -C /opt/grc -xpf ~/certs.tar && rm ~/certs.tar
# 旧VM
rm ~/certs.tar
```

**方法2: 作り直す。** アプリは `sslmode=require`(暗号化のみ。証明書の検証はしない)なので、新しい自己署名証明書でよい。

```bash
sudo install -d -m 755 /opt/grc/certs
sudo openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=db" \
  -keyout /opt/grc/certs/server.key -out /opt/grc/certs/server.crt
sudo chown 999:999 /opt/grc/certs/server.key /opt/grc/certs/server.crt   # 999 は postgres イメージの postgres ユーザー
sudo chmod 600 /opt/grc/certs/server.key
sudo chmod 644 /opt/grc/certs/server.crt
```

Postgres は秘密鍵の権限が緩い(group/other に読み書きが付いている)と起動しない。以降、この権限は変えない。

### 4. Caddy(リバースプロキシ)

```bash
sudo apt-get install -y caddy
sed 's/<HOST>/ここに公開するホスト名/' deploy/Caddyfile | sudo tee /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl enable --now caddy
sudo systemctl reload caddy
```

- 学内専用の名前なら、`deploy/Caddyfile` のコメントのとおり `tls internal` を足す。
- DNS が新VMを向く前は、Let's Encrypt の証明書は取れず、`journalctl -u caddy` にエラーが出る。切り替え(9)のあとで解消する。

### 5. デプロイ用スクリプト・runner・バックアップ

**順番が大事。`grc-deploy` は `grc-backup` を呼ぶので、`grc-backup` を先に入れる。**

#### 5-1. バックアップ([db-backup.md](db-backup.md) の「VM への配置」と同じ)

```bash
cd ~/grc-repo
sudo install -o root -g root -m 755 deploy/grc-backup /usr/local/bin/grc-backup
sudo install -o root -g root -m 644 deploy/grc-backup.service deploy/grc-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now grc-backup.timer
```

#### 5-2. デプロイスクリプトと sudoers([deploy-runner.md](deploy-runner.md) の手順 1〜3)

```bash
sudo useradd -m -s /bin/bash grc-runner
sudo install -o root -g root -m 755 deploy/grc-deploy /usr/local/bin/grc-deploy
bash -n /usr/local/bin/grc-deploy

sudo visudo -f /etc/sudoers.d/grc-runner
#   grc-runner ALL=(root) NOPASSWD: /usr/local/bin/grc-deploy
sudo chmod 440 /etc/sudoers.d/grc-runner
sudo -l -U grc-runner          # grc-deploy だけが出ること
```

`visudo` は nano で開くことが多い。開いたら次の順に操作する。

1. 次の1行を入力(または貼り付け)する。行頭に空白や全角文字が混ざらないようにする。
   ```
   grc-runner ALL=(root) NOPASSWD: /usr/local/bin/grc-deploy
   ```
2. **Ctrl+O** で書き込む。下に `File Name to Write: ...` と出るので、そのまま **Enter** を押す。
3. **Ctrl+X** で nano を閉じる。

閉じるときに `visudo` が文法を自動でチェックする。

- 問題がなければ、そのままシェルに戻る。
- 文法エラーがあると `What now?` と聞かれる。**`e` を押して**編集に戻り、直す。
  **`Q` は押さない。** `Q` で保存すると、壊れた設定のまま `sudo` が使えなくなることがある。
- 保存せずに閉じたいときは、Ctrl+X のあと `Save modified buffer?` で **N** を押す。

Ubuntu 26.04 は `sudo` が `sudo-rs` になっていることがあり、`visudo` のエラー画面の文言が少し違う場合がある。
その場合も、エラーが出たら保存せずに編集に戻って直す。

#### 5-3. runner は**まだ登録しない**

新旧の runner が両方 `self-hosted` で動いていると、GitHub Actions のデプロイジョブがどちらに届くか分からない。
**切り替え(9)で、旧VMの runner を外してから新VMに登録する。**

#### 5-4. 動作確認(本番データを入れる前に)

```bash
sudo docker compose -f /opt/grc/compose.prod.yml --project-directory /opt/grc up -d --wait db
sudo /usr/local/bin/grc-backup           # "backup ok: ..." が出ること(空のDBでも取れる)
sudo sh -c 'ls -l /var/backups/grc'
sudo rm /var/backups/grc/app_production_*.dump     # 空のDBのダンプなので消してよい
```

ここで `date` や `find` の違いで失敗する場合は、スクリプトを直してから進める。
Phase A の確認はここまで。この時点では `web` は起動しない。

---

## Phase B: 切り替える

ダウンタイムはここから。**書き込みが止まってからダンプを取る**。

### 6. 旧VMで最終バックアップ

```bash
# 旧VM
compose="docker compose -f /opt/grc/compose.prod.yml --project-directory /opt/grc"
sudo $compose stop web                    # 書き込みを止める。db は動かしたまま
sudo /usr/local/bin/grc-backup            # "backup ok: <ファイル名>" を控える
cat /var/lib/grc/deployed_sha             # デプロイ済みの SHA を控える
```

ダンプは root しか読めない。自分のホームにコピーして、転送したら消す。

```bash
f=$(sudo sh -c 'ls -t /var/backups/grc/app_production_*.dump | head -1')
sudo cp "$f" ~/app_production.dump && sudo chown "$USER" ~/app_production.dump && chmod 600 ~/app_production.dump
```

```bash
# 手元のPCで
scp -3 <旧VM>:~/app_production.dump <新VM>:~/app_production.dump
```

転送後、**旧VMと新VMの両方でハッシュを比べる**。

```bash
sha256sum ~/app_production.dump           # 旧VMと新VMで一致すること
```

### 7. 新VMへDBを復元

```bash
# 新VM
compose="docker compose -f /opt/grc/compose.prod.yml --project-directory /opt/grc"
sudo $compose up -d --wait db
sudo $compose exec -T db psql -U app -d app_production -Atc '\dt'    # 空であること

cat ~/app_production.dump | sudo $compose exec -T db pg_restore -U app -d app_production --no-owner --clean --if-exists
```

件数が旧VMと同じか確かめる。同じSQLを旧VMと新VMで実行し、結果のファイルを比べる。

長い1行を貼ると、貼り付けで引用符が崩れてシェルが続きの入力を待ち、固まったように見えることがある。
そこで、**引用符を使わないヒアドキュメント(`<<'SQL'`)**で渡す。SQLの部分は、そのままコピーして貼れる。

- 新しくSSHで入り直したときは、`compose` が消えているので、**定義し直す**(上のコードブロックの1行目)。
- `sudo` のパスワードを聞かれて、出力をファイルに向けると入力待ちが隠れる。先に `sudo -v` で認証を通しておく。

```bash
# 新VM(旧VMでも、同じものを ~/count_old.txt に出力する)
compose="docker compose -f /opt/grc/compose.prod.yml --project-directory /opt/grc"
sudo -v

sudo $compose exec -T db psql -U app -d app_production -At <<'SQL' > ~/count_new.txt
SELECT table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text::int AS rows
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;
SQL

cat ~/count_new.txt            # テーブル名|件数 の行が並ぶこと
sha256sum ~/count_new.txt      # 旧VMの ~/count_old.txt と同じ値になること
```

- 件数が**全部 0**なら、復元が実行されていないか失敗している。`sudo $compose exec -T db psql -U app -d app_production -Atc '\dt'` でテーブルがあるか確認し、なければ上の `pg_restore` をやり直す。
- ハッシュが違うときは、手元のPCから2つのファイルを並べて見る。新VMから旧VMへは SSH しない。
  例: `diff <(ssh <旧VM> cat count_old.txt) <(ssh <新VM> cat count_new.txt)`
- 画面に出す前にファイルへ向けて固まる場合は、`> ~/count_new.txt` を外して画面に出し、どこで止まるか見る。
  DBの状態は `sudo $compose exec -T db psql -U app -d app_production -c "SELECT pid, state, wait_event_type, wait_event FROM pg_stat_activity WHERE datname = 'app_production';"` で確認できる。

確認できたら、ダンプを消す。

```bash
rm ~/app_production.dump ~/count_new.txt        # 新VM
rm ~/app_production.dump ~/count_old.txt        # 旧VM
```

### 8. 新VMでデプロイ

旧VMでデプロイ済みだった SHA(6で控えたもの)をそのままデプロイする。移行と同時にコードは変えない。

```bash
sudo /usr/local/bin/grc-deploy <6で控えたSHA>
```

`pull → バックアップ → db:migrate → up -d → ヘルスチェック` が動き、最後に `deployed <SHA>` と出れば成功。
失敗したら `sudo $compose logs --tail 100 web` を見る。

```bash
curl -fsS http://127.0.0.1:3000/up            # 200
curl -fsSI https://<HOST>/ | head -n 1         # DNS を切り替える前は、hosts の一時書き換えなどで確認する
```

DNS を切り替える前に確認したいときは、手元のPCの `/etc/hosts` に一時的に新VMを向ける行を足して、ブラウザで開く。確認後に必ず戻す。

### 9. 接続先と runner を切り替える

1. **DNS を新VMに向ける**(またはIPを入れ替える)。Caddy が証明書を取れたか確認する:
   `sudo journalctl -u caddy -n 30`
2. **旧VMの runner を外す。** 手順は [deploy-runner.md](deploy-runner.md) の「4. runner の登録」の最初のブロック(`svc.sh stop` / `uninstall` / `config.sh remove`)。
   GitHub の Settings → Actions → Runners で、旧VMのものが消えたことも確認する。
3. **新VMに runner を登録する**(同じ手順の続き。`grc-runner` で登録し、root で `svc.sh install grc-runner && svc.sh start`)。
4. runner の動作確認(deploy-runner.md の「5. 動作確認」)を通す。

---

## Phase C: 確認と後片付け

### 10. 確認

```bash
sudo $compose ps                                          # web / db が Up、db は healthy
curl -fsS http://127.0.0.1:3000/up
cat /var/lib/grc/deployed_sha                             # 旧VMと同じ SHA
systemctl list-timers grc-backup.timer                    # NEXT に次の 03:30
systemctl list-units 'actions.runner.*'                   # active (running)
ps -eo user,pid,cmd | grep Runner.Listener                # 1列目が grc-runner
```

ブラウザで、ログイン・成績の表示・PDFの取り込み(Ghostscript を使う機能)を一通り試す。
**GitHub Actions の動作確認**として、軽い変更(ドキュメントなど)を main に入れて、新VMにデプロイされることを確認する。

最後に、**新VMを再起動**して、勝手に戻ることを確かめる([vm-operations.md](vm-operations.md) の「1. VM を再起動するとき」)。

### 11. 旧VMの停止と消去

- 切り替え後、**数日〜2週間は旧VMを停止だけして残す**(`sudo $compose stop`)。問題があれば戻せる。
- 旧VMには成績データが残っている。不要になったら、ダンプ・`pgdata` ボリューム・`/opt/grc/.env`・`/var/backups/grc` を消してから、VMごと破棄する。
  `docker compose down -v` でボリュームも消えるので、**消すのが旧VMであることを確かめてから**実行する。
- `.env` の `DB_PASSWORD` と `SECRET_KEY_BASE` は、旧VMでも使っていた値。旧VMが外から触れる状態だったなら、移行後に新しい値へ変える(変えるとセッションは切れる)。

---

## 切り戻し(新VMで問題が出たとき)

Phase B の途中までなら、旧VMはデータを持ったまま止まっているだけなので、戻せる。

```bash
# 旧VM
sudo $compose start web
curl -fsS http://127.0.0.1:3000/up
```

DNS を新VMに向けたあとなら、DNS を旧VMに戻す。
**新VMで書き込みが発生したあとに戻すと、その間のデータは旧VMにない。** 戻す前に新VMでバックアップを取り、必要なら旧VMに復元する。
runner も、旧VM側に戻すなら登録し直す。

## 確認チェックリスト

- [ ] 新VMのタイムゾーンが旧VMと同じ
- [ ] 新VMの `authorized_keys` に、今必要な人の鍵だけが入っている(フィンガープリントで照合済み)
- [ ] `ufw` で 22 / 80 / 443 だけ許可、SSH はパスワード認証なし
- [ ] `/opt/grc/.env` は root 所有・600
- [ ] `/opt/grc/certs` の権限が変わっていない(`server.key` は 600)
- [ ] ダンプのハッシュが旧VMと新VMで一致
- [ ] 復元後の件数が旧VMと一致
- [ ] `deployed_sha` が旧VMと同じ
- [ ] Caddy で HTTPS の証明書が取れている
- [ ] 旧VMの runner が GitHub から消え、新VMの runner が Idle になっている
- [ ] main への push で新VMにデプロイされる
- [ ] バックアップのタイマーが動き、ダンプが増えている
- [ ] 新VMを再起動しても全て戻る
- [ ] 旧VMのデータを消した(または消す期限を決めた)
