# Docker Runtime Probe Usage

`--runtime-probe` は、通常の静的チェック後に Docker イメージをビルドし、ビルド済みイメージ内で `ksh` と `java -version` が実行できるか確認する任意機能です。

既定では無効です。Docker daemon を起動し、対象の Dockerfile がローカルで build できる状態のときだけ利用してください。

## 基本

```bash
./docker-context-checker.sh -c /path/to/context -f Dockerfile --runtime-probe
```

実行時には次を行います。

1. `docker info` で Docker CLI と daemon を確認します。
2. `docker build -f <Dockerfile> -t <probe-image> <context>` を実行します。
3. `docker run --rm --entrypoint /bin/sh <probe-image> -c 'command -v ksh ...'` で `ksh` を確認します。
4. `docker run --rm --entrypoint /bin/sh <probe-image> -c 'command -v java; java -version'` で Java を確認します。
5. 自動生成した一時イメージは、既定で削除します。

## オプション

```bash
--runtime-probe
```

Docker build/run による実行プローブを有効化します。

```bash
--no-runtime-probe
```

実行プローブを無効化します。既定でも無効ですが、共通オプションを上書きしたい場合に使います。

```bash
--runtime-probe-image docker-context-checker-probe:mycase
```

プローブ用に build するイメージタグを指定します。指定したタグは自動削除しません。

```bash
--runtime-probe-keep-image
```

自動生成した一時イメージも削除せず残します。失敗調査で `docker run -it` したい場合に使います。

```bash
--runtime-probe-build-option "--secret=id=maven_settings,src=/secure/settings.xml"
--runtime-probe-build-option "--build-arg=APP_ENV=test"
```

`docker build` へ追加オプションを渡します。複数回指定できます。BuildKit build secrets、build args、network指定などが必要な Dockerfile で使います。

## 出力される主なコード

| Code | Meaning |
| --- | --- |
| `KSH001` | Dockerfile final stageでkshパッケージ導入を検出 |
| `KSH002` | final stageでkshを使っているが、ksh導入が静的には見つからない |
| `KSH003` | Dockerfile `SHELL` またはスクリプトshebangがkshを要求しているが、ksh導入が静的には見つからない |
| `KSH004` | entrypointなど実行時シェルでkshを導入している疑い |
| `RTP001` | Docker CLIまたはdaemonを利用できない |
| `RTP002` | プローブ用の `docker build` が失敗 |
| `RTP003` | `ksh` 実行プローブ成功 |
| `RTP004` | `ksh` 実行プローブ失敗 |
| `RTP005` | `java -version` 実行プローブ成功 |
| `RTP006` | `java -version` 実行プローブ失敗 |
| `RTP007` | 一時イメージの自動削除に失敗 |

## 注意

- プローブは `--entrypoint /bin/sh` でアプリ本来の entrypoint を迂回します。アプリ起動確認ではなく、`ksh` と `java` の実行可能性確認です。
- `/bin/sh` が存在しない特殊なイメージでは、`ksh` や Java が存在してもプローブが失敗することがあります。
- Dockerfile が build secrets を必須にしている場合は、`--runtime-probe-build-option "--secret=..."` を指定してください。
- Docker build が外部ネットワークやプライベートレジストリに依存する場合、その認証や接続状態も通常の `docker build` と同じく必要です。
