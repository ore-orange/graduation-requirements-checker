# 学科サーバーVMのチームメンバー用ユーザーの作り方

VM に SSH で入るメンバーのユーザーを作り、公開鍵でログインできるようにするまでの手順。
VM の全体の運用は [vm-operations.md](vm-operations.md)、新VMへの移行は [vm-migration.md](vm-migration.md) を参照。

このリポジトリは公開なので、ホスト名・IP・学籍番号などのユーザー名・鍵・パスワードは、ここにもPR・Issueにも書かない。
以降は `<ユーザー名>` `<新VM>` のように書く。

## 方針

- **1人に1ユーザー、1端末に1鍵。** 共有ユーザーや、1組の鍵を全員で使い回すことはしない。誰が入ったかをログで追え、辞めた人や紛失した端末の鍵だけを無効にできる。
- **ログインは公開鍵だけ。** パスワードでは入れない(SSH のパスワード認証は切る。[6](#6-ssh-のパスワード認証を無効にする))。
- **`sudo` は運用に必要な人だけ。** `sudo` は root と同じ。このVMには本番DBと `.env` があり、成績データも入っている。
- **`docker` グループには入れない。** `docker` グループは root 相当で、操作の記録も残らない(runner の最小権限化と同じ考え方。[deploy-runner.md](deploy-runner.md))。

## 全体の流れ

```
メンバー: 1. 自分の端末で鍵を作る → 公開鍵(.pub)だけを管理者に送る
管理者  : 2. 受け取った公開鍵でユーザーを作る(add_member)
メンバー: 3. ログインできることを確認する
管理者  : 4. 必要な人だけ sudo を与える   5. 全員が鍵で入れたら、パスワード認証を切る
```

> 渡すのは**公開鍵**(`.pub` の中身、`ssh-ed25519 AAAA...` の1行)だけ。
> **秘密鍵**(`id_ed25519` など、`.pub` が付かない方)は、誰にも渡さず、端末の外に出さない。

---

## 1. メンバー: 自分の端末で鍵を作る

すでに鍵があるか確認する。

```bash
ls -l ~/.ssh
```

`id_ed25519` と `id_ed25519.pub` があれば、それを使ってよい。なければ作る。

```bash
ssh-keygen -t ed25519 -C "<名前>-<端末名>"
```

- 保存先は、そのまま Enter でよい(`~/.ssh/id_ed25519`)。
- **パスフレーズを付ける。** 端末を盗まれても、鍵を使われにくくなる。
- コメント(`-C`)には、誰のどの端末かが分かる名前を付ける。管理者が鍵の一覧を見たときの目印になる。

公開鍵を表示して、**その1行だけ**を管理者に送る(チャットやメールでよい)。

```bash
cat ~/.ssh/id_ed25519.pub
```

同じ端末を複数のユーザー名で使う場合や、鍵を別の名前で作った場合は、あとの [3](#3-メンバー-ログインを確認する) の `~/.ssh/config` で指定する。

---

## 2. 管理者: ユーザーを作る

新VMで実行する。先に、次の関数を定義する(シェルを開き直すたびに必要)。

```bash
add_member() {
  user="$1"; keyfile="$2"
  if [ -z "$user" ] || [ ! -f "$keyfile" ]; then
    echo "使い方: add_member <ユーザー名> <公開鍵ファイル>" >&2; return 1
  fi
  if grep -q 'PRIVATE KEY' "$keyfile"; then
    echo "これは秘密鍵です。使わずに破棄し、メンバーに鍵を作り直してもらってください。" >&2; return 1
  fi
  if [ "$(wc -l < "$keyfile")" -ne 1 ]; then
    echo "公開鍵は1行のはずです。" >&2; return 1
  fi
  ssh-keygen -lf "$keyfile" >/dev/null || { echo "公開鍵として読めません。" >&2; return 1; }

  getent passwd "$user" >/dev/null || sudo adduser --disabled-password --gecos "" "$user" || return 1
  sudo install -d -o "$user" -g "$user" -m 700 "/home/$user/.ssh"
  sudo install -o "$user" -g "$user" -m 600 "$keyfile" "/home/$user/.ssh/authorized_keys"
  sudo ssh-keygen -lf "/home/$user/.ssh/authorized_keys"      # 登録された鍵のフィンガープリントを表示
}
```

受け取った公開鍵を**ファイルにして**から渡す。鍵の文字列を引数に直接渡すと、引用符を付け忘れたときに先頭の1語(`ssh-ed25519`)しか入らず、ログインできなくなる。

```bash
cat > ~/member.pub          # 受け取った1行を貼り付けて、Ctrl+D
add_member <ユーザー名> ~/member.pub
rm ~/member.pub
```

最後に `256 SHA256:... <コメント> (ED25519)` と出れば、鍵として正しく入っている。

関数が行うこと:

| 処理 | 理由 |
|---|---|
| 秘密鍵が送られていないか検査する | 間違えて秘密鍵を送ってしまう事故を防ぐ。**秘密鍵が送られてきたら、その鍵は使わず、メンバーに作り直してもらう** |
| 1行の公開鍵として読めるか検査する | 壊れた鍵を登録しない |
| `--disabled-password` でユーザーを作る | パスワードを持たせない。鍵だけでログインさせる |
| `.ssh` を 700、`authorized_keys` を 600、所有者を本人にする | sshd は、他人に書き込める権限だと鍵を拒否する(`bad ownership or modes`) |

この関数は `authorized_keys` を**置き換える**。同じユーザーに端末を追加する場合は、[7](#7-鍵の追加差し替え失効) の追記を使う。

---

## 3. メンバー: ログインを確認する

```bash
ssh <ユーザー名>@<新VM>
```

初めての接続では、ホストを信頼するか聞かれる。**管理者に、新VMのホスト鍵のフィンガープリントを聞いて照合してから** `yes` と答える(管理者は新VMで `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` を実行する)。

鍵のパスフレーズを聞かれる(`Enter passphrase for key '...'`)のは正常。**VM のパスワードではなく、手元の秘密鍵のパスフレーズ。**

### 鍵を別の名前で作った場合・複数ある場合

`~/.ssh/config` に書くと、毎回 `-i` を付けなくてよい。

```
Host grc-new
    HostName <新VMのIP>
    User <ユーザー名>
    IdentityFile ~/.ssh/<秘密鍵のファイル名>
```

```bash
chmod 600 ~/.ssh/config
ssh grc-new                      # 別名で入る(IPを直接指定すると、この設定は使われない)
```

`IdentityFile` と `-i` で指定するのは**秘密鍵**(`.pub` が付かない方)。

### 管理者: 入れたことをサーバーのログで確認する

```bash
sudo journalctl -u ssh -n 10 --no-pager | grep Accepted
# Accepted publickey for <ユーザー名> from ... ED25519 SHA256:...
```

`SHA256:...` が、メンバーの端末の `ssh-keygen -lf ~/.ssh/id_ed25519.pub` と同じなら、期待どおりの鍵で入っている。

---

## 4. 管理者: sudo 権限を与える

**運用(デプロイの確認、ログの調査、再起動など)に関わる人だけ**に与える。閲覧やテストだけの人は、一般ユーザーのままにする。

```bash
u=<ユーザー名>
sudo usermod -aG sudo "$u"
id "$u"                          # groups に sudo が入っていること
```

`add_member` で作ったユーザーはパスワードを持たないため、このままでは `sudo` を使えない(`sudo` は本人のパスワードを聞く)。一時パスワードを設定し、次回ログインで本人に変更させる。

```bash
sudo passwd "$u"                 # 一時パスワードを入力する
sudo passwd -e "$u"              # 次回ログイン時に、パスワードの変更を強制する
```

メンバーは、鍵でログインしたあと、新しいパスワードの設定を求められる。確認:

```bash
sudo -l -U "$u"                  # (ALL : ALL) ALL と出る
# メンバー本人が
sudo -v                          # パスワードを入力して通る
```

**パスワードを設定したら、SSH のパスワード認証を切っておく([6](#6-ssh-のパスワード認証を無効にする))。** 切っていないと、そのパスワードで SSH に入れてしまう。

| やらないこと | 理由 |
|---|---|
| `docker` グループに入れる | root 相当で、記録も残らない。Docker の操作は `sudo` 経由 |
| `NOPASSWD` にする | 鍵を盗まれた時点で root を取られる。例外は runner の `grc-deploy` だけ |
| `sudo docker compose *` のように、ワイルドカードで許可する | 引数でファイルのマウントなどができて、結局 root と同じ |

取り消し:

```bash
sudo gpasswd -d "$u" sudo
```

誰がいつ `sudo` を使ったかは、ログに残る。

```bash
sudo journalctl _COMM=sudo --no-pager | tail -n 20
```

Ubuntu 26.04 では `sudo` が `sudo-rs` になっていることがあり、ログの形式が少し違う場合がある。

---

## 5. 管理者: 全員が鍵で入れたことを確認する

パスワード認証を切る前に、鍵でログインできたユーザーを確認する。ここに出ていないユーザーは、切ったあと入れなくなる。

```bash
sudo journalctl -u ssh --no-pager | grep 'Accepted publickey' | awk '{for(i=1;i<=NF;i++) if($i=="for") print $(i+1)}' | sort | uniq -c
```

---

## 6. SSH のパスワード認証を無効にする

`/etc/ssh/sshd_config` を `sed` で書き換える方法は、**効かないことがある**。Ubuntu は `sshd_config` の先頭で `/etc/ssh/sshd_config.d/*.conf` を読み込み、sshd は**最初に見つかった値を採用する**ため。クラウドイメージでは `50-cloud-init.conf` が `PasswordAuthentication yes` を持っていることがある。
そこで、最初に読まれる名前の設定ファイルを作る。

切る前に、次の2つを確保する。
- [5](#5-管理者-全員が鍵で入れたことを確認する) で、メンバー全員が鍵で入れていること。
- 鍵が通らなくなったときの復旧手段(`sudo` を使える人がもう1人いる、またはVMのコンソールから入れること)。

**いまのセッションは、最後まで閉じない。**

```bash
sudo tee /etc/ssh/sshd_config.d/00-disable-password.conf >/dev/null <<'EOF'
# SSH はパスワードでは入れない。公開鍵だけにする。
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
EOF
sudo chmod 644 /etc/ssh/sshd_config.d/00-disable-password.conf

sudo sshd -t && echo "syntax ok"          # 何か出力されたら反映せずに直す
sudo systemctl reload ssh                  # いまの接続は切れない
```

### エディタ(vi)で編集する場合

`tee` の代わりに `vi` で書いてもよい。内容は同じ。

```bash
sudo vi /etc/ssh/sshd_config.d/00-disable-password.conf
```

1. **`i`** を押して、入力モードにする(画面下に `-- INSERT --` と出る)。
2. 次の内容を入力(または貼り付け)する。

   ```
   # SSH はパスワードでは入れない。公開鍵だけにする。
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PubkeyAuthentication yes
   PermitRootLogin no
   ```

3. **`Esc`** を押して、入力モードを抜ける。
4. **`:wq`** と入力して Enter。書き込んで終了する。
   - 保存せずに終了するときは **`:q!`** と入力して Enter。

そのあとの `sshd -t` と `reload` は、上のコードブロックと同じ。

- 既存のファイル(`/etc/ssh/sshd_config` や `50-cloud-init.conf` の値)を直す場合も、同じ操作でよい。
  ただし、`sshd_config.d` の中に `PasswordAuthentication yes` が残っていると、**そちらが先に読まれて優先される**。直したあとは、必ず `sudo sshd -T | grep -i '^passwordauthentication'` で、実際に `no` になっているか確認する。
- Ubuntu の `vi` が簡易版(`vim-tiny`)だと、入力モードで矢印キーを押すと `A` `B` などの文字が入ることがある。その場合は `Esc` で抜けて、`h` `j` `k` `l` で移動するか、`:set nocompatible` と入力してから続ける。
- 編集中に `sudo` を付け忘れて `vi` で開くと、`:wq` で保存できない(`E45: 'readonly' option is set` など)。`:q!` で抜けて、`sudo vi` で開き直す。

| 行 | 意味 |
|---|---|
| `PasswordAuthentication no` | パスワード認証を無効にする |
| `KbdInteractiveAuthentication no` | PAM 経由の対話認証(パスワードを聞く別の経路)も無効にする |
| `PubkeyAuthentication yes` | 公開鍵認証を有効にする |
| `PermitRootLogin no` | root での SSH ログインを禁止する |

反映された値を確認する。

```bash
sudo sshd -T | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication) '
# passwordauthentication no / kbdinteractiveauthentication no / permitrootlogin no / pubkeyauthentication yes
```

`passwordauthentication yes` のままなら、別のファイルが先に読まれている。
`sudo grep -rE 'PasswordAuthentication' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/` で見つけて直す。

**別の端末で**動作を確認する(いまのセッションは閉じない)。

```bash
ssh <ユーザー名>@<新VM>                                                                    # 鍵で入れる
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password <ユーザー名>@<新VM>    # Permission denied (publickey). で拒否される
```

戻すとき(締め出されたら、VMのコンソールから):

```bash
sudo rm /etc/ssh/sshd_config.d/00-disable-password.conf
sudo systemctl reload ssh
```

---

## 7. 鍵の追加・差し替え・失効

### 端末を追加する(同じ人の2台目)

新しい端末で鍵を作り([1](#1-メンバー-自分の端末で鍵を作る))、その公開鍵を**追記**する。`add_member` は置き換えるので使わない。

```bash
cat > ~/member.pub                         # 受け取った1行を貼り付けて Ctrl+D
ssh-keygen -lf ~/member.pub                # 公開鍵として読めるか確認
sudo tee -a /home/<ユーザー名>/.ssh/authorized_keys < ~/member.pub >/dev/null
sudo wc -l /home/<ユーザー名>/.ssh/authorized_keys            # 鍵の数と行数が合うこと
sudo ssh-keygen -lf /home/<ユーザー名>/.ssh/authorized_keys   # 全部の鍵が読めること
rm ~/member.pub
```

### 端末を紛失した・鍵が漏れた

その1行だけを消す。フィンガープリントで、どの行かを特定する。

```bash
sudo ssh-keygen -lf /home/<ユーザー名>/.ssh/authorized_keys     # 一覧を見る
sudo nl /home/<ユーザー名>/.ssh/authorized_keys                 # 行番号を見る
sudo sed -i '<行番号>d' /home/<ユーザー名>/.ssh/authorized_keys
```

その人は、新しい端末で鍵を作り直して、公開鍵を送り直す。

### メンバーが抜けた

ログインできないようにする。まず無効化して、問題がなければ、あとで削除する。

```bash
sudo usermod --expiredate 1 <ユーザー名>                  # アカウントを失効させる(鍵でも入れなくなる)
sudo gpasswd -d <ユーザー名> sudo 2>/dev/null             # sudo グループにいれば外す
sudo pkill -KILL -u <ユーザー名>                          # ログイン中のセッションを切る

# 削除してよいと決めたら(ホームのデータも消える)
sudo deluser --remove-home <ユーザー名>
```

`authorized_keys` を消すだけでは、パスワードが設定されていた場合に残る。必ず `--expiredate 1` で失効させる。

---

## 8. うまくいかないとき

サーバーのログが、一番早い手がかり。メンバーがログインを試した**直後**に見る。

```bash
sudo journalctl -u ssh -n 20 --no-pager
```

| ログ・症状 | 原因 | 対処 |
|---|---|---|
| `Invalid user <名前>` / パスワードを聞かれる | その名前のユーザーが VM にない。ユーザー名の綴り違い、または未作成 | `getent passwd <ユーザー名>` で確認。なければ [2](#2-管理者-ユーザーを作る) |
| `Failed publickey for <名前> ... SHA256:xxxx` | 鍵は届いているが、`xxxx` が登録した鍵と違う(別の端末の鍵を送った、など) | メンバーの `ssh-keygen -lf ~/.ssh/<鍵>.pub` と、サーバーの `sudo ssh-keygen -lf /home/<名前>/.ssh/authorized_keys` を見比べ、一致する鍵を登録し直す |
| `Failed publickey` も `Accepted` も出ず、パスワードを聞かれる | 鍵が**提示されていない** | 下の「`type -1`」 |
| `Authentication refused: bad ownership or modes for directory/file ...` | ホーム・`.ssh`・`authorized_keys` の所有者か権限が違う | `sudo chown -R <名前>:<名前> /home/<名前>/.ssh`、`.ssh` を 700、`authorized_keys` を 600、ホームを 755 以下に |
| `Connection closed by authenticating user ... [preauth]` のみ | パスワード入力を待ったまま、メンバーが中断した(鍵が提示されなかった) | 上と同じ |
| `Connection refused` / `timed out` | 22番に届かない。学内ネットワークかVPNに繋いでいない、または ufw で止まっている | 学内ネットワークかVPNに繋ぐ。`sudo ufw status` |

### メンバーの端末で、鍵が提示されているか見る

```bash
ssh -v <ユーザー名>@<新VM> 2>&1 | grep -E 'identity file|Offering|Server accepts|Authentications that can continue|Authenticated'
```

| 出力 | 意味 | 対処 |
|---|---|---|
| `identity file ... type -1` だけ | **その場所に秘密鍵がない** | `ls ~/.ssh` で確認。なければ [1](#1-メンバー-自分の端末で鍵を作る)。別の名前なら `-i` か `~/.ssh/config` で指定 |
| `type 3` はあるが `Offering public key` が出ない | 鍵が使われていない | `ssh -i ~/.ssh/<秘密鍵> -o IdentitiesOnly=yes <ユーザー名>@<新VM>` で直接試す |
| `Offering public key` のあと、パスワードに戻る | 提示した鍵が、サーバーに登録した鍵と違う | 上の `Failed publickey` の行と同じ |
| `Authenticated ... using "publickey"` | 成功 | |

設定ファイルの影響を除いて、鍵だけで試す。

```bash
ssh -i ~/.ssh/<秘密鍵> -o IdentitiesOnly=yes -o PreferredAuthentications=publickey <ユーザー名>@<新VM>
```

これで入れるなら、鍵と登録は正しく、`~/.ssh/config` の書き方が原因。`ssh -G grc-new | grep -iE '^(hostname|user|identityfile) '` で、実際に使われる設定を確認できる。

### `ssh-copy-id` が使えない理由

`ssh-copy-id` は、**すでにログインできる人**(パスワードか、登録済みの鍵)でないと使えない。新しいメンバーは、まだ入る手段がないので、この手順のように、公開鍵を管理者に送って登録してもらう。パスワード認証を切ったあとは、なおさら使えない。Windows の標準の OpenSSH には、`ssh-copy-id` 自体がない。

### パスワードの入力欄の見分け方

| 表示 | 意味 |
|---|---|
| `Enter passphrase for key '...':` | 手元の**秘密鍵のパスフレーズ**。鍵ログインは成功している。入力すれば入れる |
| `<ユーザー>@<新VM>'s password:` | VM のパスワード。鍵が通らず、パスワード認証に切り替わった |

---

## チェックリスト

- [ ] メンバーが、自分の端末で鍵を作った(パスフレーズ付き)
- [ ] 受け取ったのは公開鍵(`.pub`)だけで、秘密鍵ではない
- [ ] `add_member` を実行し、`ssh-keygen -lf` で鍵が読めた
- [ ] `/home/<ユーザー名>`、`.ssh`(700)、`authorized_keys`(600)の所有者が本人
- [ ] メンバーが鍵で入れて、ログの `Accepted publickey` のフィンガープリントが端末の鍵と一致した
- [ ] `sudo` を与えるのは、運用に必要な人だけ。`docker` グループには入れていない
- [ ] 全員が鍵で入れることを確認してから、SSH のパスワード認証を切った
- [ ] 切ったあと、別の端末で、鍵では入れてパスワードでは入れないことを確認した
- [ ] 抜けたメンバーは `--expiredate 1` で失効させた
