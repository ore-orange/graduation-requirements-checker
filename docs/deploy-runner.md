# デプロイ用 self-hosted runner の構成と権限

学科サーバーVMへのデプロイは、VM上の self-hosted runner が行う。
このリポジトリは公開なので、runner が乗っ取られても被害が小さくなるよう、
runner の権限を「指定したSHAをデプロイする」ことだけに絞っている。

## 全体像

```
main へ push → CI 成功 → Deploy ワークフロー
  ├─ build  (ubuntu-latest) イメージを ghcr.io に push (:latest と :<SHA>)
  └─ deploy (self-hosted)   sudo /usr/local/bin/grc-deploy <SHA>
                              └─ pull → db:migrate → up -d → ヘルスチェック
```

- runner は専用ユーザー `grc-runner` で動く。`docker` / `sudo` グループには入れない。
- `grc-runner` が sudo で実行できるのは `/usr/local/bin/grc-deploy` だけ。
- compose 定義(`/opt/grc/compose.prod.yml`)は VM 側に固定する。ワークフローからは書き換えない。
- `docker` グループは root 相当なので、runner を入れないことが要点。専用ユーザーにするだけでは権限は減らない。

## なぜこうしたか

| 懸念 | 対策 |
|---|---|
| runner が個人ユーザー(sudo・docker 所属)で動いていた | 専用ユーザー `grc-runner` に変更し、グループには入れない |
| runner が乗っ取られると VM の root を取られる | sudoers で `grc-deploy` のみ許可。スクリプトは root 所有で書き換え不可 |
| ワークフローで compose 定義を差し替えられる | compose 定義を VM 側に固定。ワークフローは SHA を渡すだけ |
| 任意の文字列を渡される | スクリプトが SHA(40桁の16進)の形式を検証する |
| フォークの PR からデプロイされる | `workflow_run` の条件(push・同一リポジトリ・CI成功)で防ぐ。CI のジョブは全て `ubuntu-latest` |

残るリスク: main に入ったコードのイメージは本番で動く。ブランチ保護(レビュー必須)が最後の防御になる。

## VM 側のセットアップ手順

### 1. runner 専用ユーザー

```bash
sudo useradd -m -s /bin/bash grc-runner
id grc-runner   # groups が grc-runner だけであること
```

### 2. デプロイスクリプト

`deploy/grc-deploy` を `/usr/local/bin/grc-deploy` に置く。

```bash
sudo install -o root -g root -m 755 deploy/grc-deploy /usr/local/bin/grc-deploy
bash -n /usr/local/bin/grc-deploy
```

スクリプトを変えたときも、同じコマンドで VM に入れ直す(自動では反映されない)。

### 3. sudoers

```bash
sudo visudo -f /etc/sudoers.d/grc-runner
```

```
grc-runner ALL=(root) NOPASSWD: /usr/local/bin/grc-deploy
```

```bash
sudo chmod 440 /etc/sudoers.d/grc-runner
sudo -l -U grc-runner   # (root) NOPASSWD: /usr/local/bin/grc-deploy だけが出ること
```

visudo が文法エラーを出したら `e` で直す。`Q` で保存すると sudo が壊れるので押さない。

### 4. runner の登録

旧 runner(個人ユーザーで動いていたもの)があれば、先に外す。

```bash
cd <旧runnerのディレクトリ>   # systemctl cat <サービス名> の ExecStart で分かる
sudo ./svc.sh stop && sudo ./svc.sh uninstall
./config.sh remove --token <削除用トークン>
```

新しい runner を `grc-runner` で登録する。

```bash
sudo -iu grc-runner
mkdir actions-runner && cd actions-runner
# GitHub の Settings > Actions > Runners > New self-hosted runner の手順でダウンロード
./config.sh --url https://github.com/ore-orange/graduation-requirements-checker --token <登録トークン>
exit
```

サービス化は root で行う。Ubuntu ではホームが 750 のため、sudo グループのユーザーでも
`/home/grc-runner` には入れない。root のシェルで実行する。

```bash
sudo bash -c 'cd /home/grc-runner/actions-runner && ./svc.sh install grc-runner && ./svc.sh start'
```

### 5. 動作確認

```bash
ps -eo user,pid,cmd | grep Runner.Listener                                 # 1列目が grc-runner
sudo -u grc-runner sudo -n /usr/local/bin/grc-deploy abc; echo "exit=$?"   # invalid sha / exit=2
sudo -u grc-runner sudo -n docker ps; echo "exit=$?"                       # パスワード要求で失敗
sudo -u grc-runner cat /opt/grc/.env; echo "exit=$?"                       # Permission denied
diff deploy/compose.prod.yml /opt/grc/compose.prod.yml                     # 差分なし
```

`.env` が読めてしまう場合は `chmod 640` にし、所有グループから `grc-runner` を外す。

## 運用上の注意

- **compose 定義を変えたとき**は、`sudo install -m 644 deploy/compose.prod.yml /opt/grc/compose.prod.yml` で手動で更新する。ワークフローは配置しない。
- **`/opt/grc/.env` を変えたとき**は、`docker compose -f /opt/grc/compose.prod.yml up -d --force-recreate web` で再作成しないと反映されない(`env_file` はコンテナ作成時に読まれる)。
- `/opt/grc/certs` の権限は変えない(Postgres の SSL 鍵)。
- 現在デプロイ済みのSHAは `/var/lib/grc/deployed_sha` に記録される。
- デプロイが失敗したときは `journalctl -u 'actions.runner.*' -n 50` で runner 側のログを見る。

## 今後の検討事項

- `deploy` ジョブに `environment: production`(必須レビュアー)を付け、デプロイ前に人の承認を挟む。
- runner の ephemeral 化(1ジョブごとに使い捨て)。
- runner 用に別VMを用意し、本番VMには forced command 付きの SSH 鍵だけで入る構成。
- GitHub の Settings > Actions > General で、外部コントリビューターのワークフローに承認を必須にする。
