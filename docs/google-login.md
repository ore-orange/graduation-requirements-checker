# Googleアカウントによるログイン

卒業要件チェッカーのログインは、学内のGoogleアカウント（`@ie.u-ryukyu.ac.jp`）で行う。
メールアドレスとパスワードによるログインも残してあるが、通常の利用者はGoogleを使う。

パスワードを残しているのは退避路のため。Googleの構成に不備があったときや、
外向きの通信が塞がれたときに、ログインする手段が完全に失われないようにしている。

## なぜGoogleなのか

メールを送る手段が無く、パスワード再設定が作れないため。
Resendのような送信サービスは、送信ドメインのDNSにSPF/DKIM/MXを設定しないと
自分のアドレスにしか送れないが、`ie.u-ryukyu.ac.jp` のDNS権限は持っていない。
Googleログインなら、DNS権限なしでメールアドレスの所有確認まで済む。

## 構成

```
ブラウザ ──POST /auth/google_oauth2──▶ アプリ（OmniAuthのミドルウェアが受ける）
         ◀──リダイレクト────────────
         ──────────────────────────▶ accounts.google.com（アカウント選択）
         ◀──GET /auth/google_oauth2/callback──
                                        アプリ ──トークン交換──▶ oauth2.googleapis.com
```

トークン交換はアプリからGoogleへの直接通信。VMからの外向きHTTPSが必要になる。
2026-11-06にVM上で実測し、`oauth2.googleapis.com` と `www.googleapis.com` へ
IPv4・IPv6のどちらでも到達できることを確認済み。コンテナは既定でIPv6を持たないため、
IPv4で通ることを別途確かめてある。

## Google Cloud Console 側の設定

プロジェクトは `grc-auth`（組織 `ie.u-ryukyu.ac.jp`）。

| 項目 | 値 |
| --- | --- |
| ユーザーの種類 | Internal |
| アプリケーションの種類 | ウェブ アプリケーション |
| スコープ | `email` / `profile` のみ |
| 承認済みのリダイレクトURI | `http://localhost:3000/auth/google_oauth2/callback`<br>`https://grc.ie.u-ryukyu.ac.jp/auth/google_oauth2/callback` |
| 承認済みのJavaScript生成元 | 空のまま |

**JavaScript生成元は使わない。** ブラウザのJSから直接Googleを呼ぶ場合の欄で、
サーバー側で受け取る今の作りでは不要。パスを含むURLを入れると入力エラーになる。

**Internalを選べたので、テストユーザーの登録もアプリの検証も不要。** 学内限定を
Google側が担保する。スコープを基本の3つに絞っているため、未審査アプリの警告画面も出ない。

**リダイレクトURIの登録に所有権の証明は要らない。** 証明が要るのは「承認済みドメイン」の
方だが、この構成では発生しない。

## 環境変数

| 変数 | 既定 | 置き場所 |
| --- | --- | --- |
| `GOOGLE_CLIENT_ID` | 無し | ローカル `.env` / 本番 `/opt/grc/.env` |
| `GOOGLE_CLIENT_SECRET` | 無し | 同上 |
| `ALLOWED_EMAIL_DOMAINS` | `ie.u-ryukyu.ac.jp` | 他学部へ広げるときにカンマ区切りで足す |
| `ALLOWED_HOSTS` | `localhost` | OmniAuthがコールバックURLを組み立てるときに使う |

`.env` はGit管理外（`.gitignore` の `/.env*`）。本番の `/opt/grc/.env` は root所有の600で、
Gitからは配れない。**VMに入れる人が直接書く以外に方法がない。**

ローカルでは `compose.yml` の `web` が `${GOOGLE_CLIENT_ID:-}` の形で受け渡す。
Docker Composeは `.env` をコンテナへ自動では渡さないため、この記述が要る。

資格情報が揃っていない環境では、ログイン画面に「Google でログイン」ボタンを出さない。
押してもエラー画面になるだけなので、導線ごと隠している。

## 実装上の注意

**`button_to` に `data: { turbo: false }` が必須。** Turboはform送信をfetchで肩代わりするが、
別ドメインへのリダイレクトを追えず、押しても何も起きない状態になる。

**OmniAuth 2.x はGETでの開始を禁じている**（CVE-2015-9284）。`link_to` ではなく
`button_to` でPOSTし、`omniauth-rails_csrf_protection` でCSRFトークンを付ける。

**`OmniAuth.config.allowed_hosts` を設定する。** コールバックURLはHostヘッダーから
組み立てられるため、偽装されると認可コードを別のホストへ送らせられる。

**`hd` パラメータは信用しない。** 利用者側から渡せる。学内判定は、Googleが所有を
確認済み（`email_verified`）のメールアドレスのドメインだけを根拠にする。
判定は `app/services/google_identity.rb` に集めてある。

**アカウントの同一性は `users.google_uid` で見る。** メールアドレスは本人が変更できる。
ただし、パスワードで登録済みの人が同じメールアドレスでGoogleを使った場合は、
別アカウントを作らず同じ行に `google_uid` を書き込む。

## 本番（学科サーバーVM）

ホスト `e245745-grache`（10.0.7.173）。`ssh -i ~/.ssh/grache e245742@10.0.7.173` で入る。
`sudo` はパスワードを要求するので、設定変更は対話で行う。

### HTTPS

`grc.ie.u-ryukyu.ac.jp` は学内限定の名前でLet's Encryptが使えないため、
`/etc/caddy/Caddyfile` で `tls internal` を指定し、Caddyの内部CAで証明書を発行している。

```
grc.ie.u-ryukyu.ac.jp {
	tls internal
	reverse_proxy 127.0.0.1:3000
}
```

**ブラウザは警告を出すが、Googleログインは成立する。** Googleがこちらのサーバーへ
接続することはなく、ブラウザがリダイレクトで戻ってくるだけのため。

証明書は12時間ごとに自動更新される。確認は以下。

```bash
echo | openssl s_client -connect grc.ie.u-ryukyu.ac.jp:443 -servername grc.ie.u-ryukyu.ac.jp 2>/dev/null \
  | openssl x509 -noout -issuer -dates -ext subjectAltName
```

`curl` が `ssl_verify_result: 20` を返すのは「発行元をたどれない」という意味で、
証明書が無いこととは別。ハンドシェイク自体は成功している。

### マスタ投入

コースマスタが空だと、学籍情報の登録画面でコースを選べない。
デプロイのたびに `master:load` が流れるよう、`/usr/local/bin/grc-deploy` に組み込んである。

```
pull → db:migrate → master:load → up -d → ヘルスチェック
```

**このスクリプトはVMへ手で入れる。** VMにリポジトリのクローンは無いので、
手元から送ってから `install` する。

```bash
# 手元
scp -i ~/.ssh/grache deploy/grc-deploy e245742@10.0.7.173:~/grc-deploy
# VM
sudo install -o root -g root -m 755 ~/grc-deploy /usr/local/bin/grc-deploy
rm ~/grc-deploy
md5sum /usr/local/bin/grc-deploy            # 手元の deploy/grc-deploy と一致すること
grep -c 'rails' /usr/local/bin/grc-deploy   # 2（db:migrate と master:load）
```

`install` を使うのは、コピーと所有者・権限の設定を一度に済ませるため。
`cp` だと所有者が自分のままになり、runnerが `sudo` で呼ぶ前提と食い違う。

### 資格情報の追加

```bash
sudo tee -a /opt/grc/.env >/dev/null <<'EOF'
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...
EOF
sudo grep -c '^GOOGLE_CLIENT' /opt/grc/.env   # 2
```

**`/opt/grc/.env` の中身は表示しない。** `SECRET_KEY_BASE` と `DB_PASSWORD` が入っている。
確認するときも件数だけを見る。

追加後、デプロイを1回走らせると反映される。

## 確認手順

1. ログイン画面に「Google でログイン」ボタンが出る
2. 押すとGoogleのアカウント選択画面へ飛ぶ（毎回選ばせる設定にしてある）
3. 学内アカウントを選ぶと戻ってきて、初回は学籍情報の登録画面が出る
4. コースと入学年度を登録するとダッシュボードが出る
5. 学外のアカウントでは、許可ドメインを案内して断る

`redirect_uri_mismatch` が出た場合は、設定ミスか反映待ちのどちらか。
コンソールの注意書きどおり、反映には時間がかかることがある。

## 作業の記録

| 日付 | 内容 |
| --- | --- |
| 2026-11-06 | 方針決定。VMからGoogleへの外向きHTTPSを実測して確認 |
| 2026-11-17 | OAuthクライアントIDを発行。アプリ側を実装（PR #89） |
| 2026-11-17 | VMの `tls internal` を設定し、HTTPSが通ることを確認 |
| 2026-11-17 | `master:load` 入りの `grc-deploy` をVMへ設置 |

### 未了

- `/opt/grc/.env` への `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` 追加
- PR #89 のマージ。マージすると自動でデプロイが走り、`master:load` も同時に流れる
