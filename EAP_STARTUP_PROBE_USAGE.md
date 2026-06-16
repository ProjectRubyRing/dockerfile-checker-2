# JBoss EAP Startup Probe Usage

`--eap-startup-probe` は、通常の静的チェック後に Docker イメージをビルドし、コンテナを通常の ENTRYPOINT/CMD で起動して、JBoss EAP 8.1 の起動ログを監視する任意機能です。

既定では無効です。Docker daemon を起動し、対象の Dockerfile がローカルで build でき、コンテナ起動に必要な環境変数やSecretを指定できる状態で利用してください。

## 基本

```bash
./docker-context-checker.sh -c /path/to/context -f Dockerfile --eap-startup-probe
```

実行時には次を行います。

1. `docker info` で Docker CLI と daemon を確認します。
2. `docker build -f <Dockerfile> -t <probe-image> <context>` を実行します。
3. `docker run -d --name <probe-container> <probe-image>` で、コンテナ本来の ENTRYPOINT/CMD を起動します。
4. `docker logs <probe-container>` を最大 `--eap-startup-timeout` 秒まで監視します。
5. 起動成功ログとWARデプロイ成功ログの両方が見つかったら成功として記録します。
6. ログ内に現れた `.war` ファイル名を抽出し、コンソールとCSV結果に表示します。
7. 自動生成した一時コンテナと一時イメージは、既定で削除します。

## 成功判定

成功には、次の両方が必要です。

- サーバー起動成功ログ: `WFLYSRV0025` を含む JBoss EAP/WildFly started ログ、または `Started N of N services` 系のログ
- WARデプロイ成功ログ: `WFLYSRV0010: Deployed "...war"`、`Deployed "...war"`、`Deployment "...war" successfully` など

ログから検出したWARファイル名は `EAP010` として出力し、ソフトウェア棚卸しCSVにも `jboss-eap-deployed-war` として追加します。

## オプション

```bash
--eap-startup-probe
```

JBoss EAP 起動プローブを有効化します。

```bash
--no-eap-startup-probe
```

JBoss EAP 起動プローブを無効化します。既定でも無効ですが、共通オプションを上書きしたい場合に使います。

```bash
--eap-startup-timeout 240
```

起動ログを待つ秒数を指定します。既定は `180` 秒です。

```bash
--eap-startup-image docker-context-checker-eap-probe:mycase
```

プローブ用に build するイメージタグを指定します。指定したタグは自動削除しません。

```bash
--eap-startup-container docker-context-checker-eap-probe-mycase
```

プローブ用コンテナ名を指定します。指定したコンテナ名は自動削除しません。

```bash
--eap-startup-keep-image
--eap-startup-keep-container
```

自動生成した一時イメージまたはコンテナを削除せず残します。失敗調査でログやファイルを確認したい場合に使います。

```bash
--eap-startup-build-option "--secret=id=maven_settings,src=/secure/settings.xml"
--eap-startup-build-option "--build-arg=APP_ENV=test"
```

`docker build` へ追加オプションを渡します。複数回指定できます。

```bash
--eap-startup-run-option "-e=APP_ENV=test"
--eap-startup-run-option "-e=DB_URL=jdbc:postgresql://example/db"
--eap-startup-run-option "-p=8080:8080"
```

`docker run` へ追加オプションを渡します。複数回指定できます。EAP起動に必要な環境変数、Secretマウント、volume、network、port公開などに使います。

## 出力される主なコード

| Code | Meaning |
| --- | --- |
| `EAP001` | Docker CLIまたはdaemonを利用できない |
| `EAP002` | プローブ用の `docker build` が失敗 |
| `EAP003` | プローブ用コンテナの起動に失敗 |
| `EAP004` | JBoss EAP起動成功ログとWARデプロイ成功ログを検出 |
| `EAP005` | 起動成功ログは見つかったがWARデプロイ成功ログが見つからない |
| `EAP006` | WARデプロイ成功ログは見つかったが起動成功ログが見つからない |
| `EAP007` | 起動ログ内に失敗を示す行を検出 |
| `EAP008` | タイムアウトまでに起動成功とデプロイ成功が揃わない |
| `EAP009` | 成功確認前にコンテナが終了 |
| `EAP010` | ログからデプロイ済みWARファイル名を検出 |
| `EAP011` | 一時イメージまたは一時コンテナの自動削除に失敗 |
| `EAP012` | 起動成功は確認したが、ログ上でJBoss EAP 8.1を明確に確認できない |

## 注意

- このプローブはアプリ本来の ENTRYPOINT/CMD を起動します。必要な環境変数や外部接続が不足すると、EAP起動やデプロイが失敗します。
- ECSで渡す予定の環境変数は、ローカル検証では `--eap-startup-run-option "-e=NAME=value"` などで渡してください。
- Dockerfile が build secrets を必須にしている場合は、`--eap-startup-build-option "--secret=..."` を指定してください。
- 起動が遅いイメージでは `--eap-startup-timeout` を増やしてください。ただし、ログが停止している場合はタイムアウト延長より起動エラーの修正が先です。
- この機能はログパターンによる判定です。EAPのログ形式を大きく変更している場合は、検出できない可能性があります。
