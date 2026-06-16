# Docker Context Checker

RHEL 9.6 / UBI 9.6 系のコンテナを想定した、Dockerfile とビルドコンテキストの静的チェック用 Bash アプリケーションです。Docker を実行せず、Dockerfile、`COPY`/`ADD` 元リソース、entrypoint から呼び出されるシェル、WildFly `jboss-cli` の CLI ファイルを横断して問題候補を一覧化します。

## 実行例

```bash
chmod +x docker-context-checker.sh
./docker-context-checker.sh --context /path/to/build-context --dockerfile Dockerfile
```

実行中は、コンソールにチェックフェーズと現在の検出数が進捗として表示されます。

```text
[12:34:56] CHECK        Parsing Dockerfile instructions and multi-stage definitions (ERROR=0 WARN=0 INFO=0)
[12:34:57] CHECK        Scanning shell script: entrypoint.sh (...) (ERROR=0 WARN=2 INFO=1)
```

entrypoint が Dockerfile から解決できない場合は明示できます。

```bash
./docker-context-checker.sh -c /path/to/context -f Dockerfile -e entrypoint.sh
```

結果は既定で、実行ディレクトリの `docker-context-checker-results.csv` にUTF-8 BOM付きCSVとして出力します。Excelでそのまま取り込めるように、各行へチェック内容、結果、対象ファイル、行数、改善提案を出します。

```bash
./docker-context-checker.sh -c /path/to/context -o result.csv
./docker-context-checker.sh -c /path/to/context --no-progress
./docker-context-checker.sh -c /path/to/context --no-output
```

CSV列:

```text
No, Result, Severity, CheckCode, CheckItem, Phase, File, Line, Message, Suggestion
```

ビルドコンテキスト内の関連図は、既定で `docker-context-relations.mmd` にMermaid形式で出力します。Dockerfileからの `COPY` / `ADD`、`ENTRYPOINT`、シェルからの呼び出し、`jboss-cli --file` 参照をエッジとして書き出します。

```bash
./docker-context-checker.sh -c /path/to/context --mermaid relations.mmd
./docker-context-checker.sh -c /path/to/context --no-mermaid
```

Dockerfileやシェルスクリプトで利用している変数の棚卸しは、既定で `docker-context-checker-variables.csv` にUTF-8 BOM付きCSVとして出力します。ARG、ENV、シェル変数、exportされた環境変数、外部から受け取る必要がある疑いの変数を、ファイル名、行数、設定値、利用形と一緒に出します。

```bash
./docker-context-checker.sh -c /path/to/context --variables-output variables.csv
./docker-context-checker.sh -c /path/to/context --no-variables-output
```

変数CSV列:

```text
No, VariableName, Category, Action, Phase, File, Line, ConfiguredValue, Note
```

ECSタスク定義で外から設定する必要、または環境ごとに上書きする可能性がある環境変数は、既定で `docker-context-checker-ecs-env.csv` にUTF-8 BOM付きCSVとして出力します。Dockerfileの `ENV`、entrypointや呼び出し先シェルの `${VAR:?message}` / `${VAR:-default}` / 未初期化参照、WildFly/JBoss CLIファイル内の `${env.NAME}` などを検出し、ECSタスク定義では `environment` に置くべきか、機密値として `secrets` に置くべきかも分類します。

```bash
./docker-context-checker.sh -c /path/to/context --ecs-env-output ecs-env.csv
./docker-context-checker.sh -c /path/to/context --no-ecs-env-output
```

ECS環境変数CSV列:

```text
No, EnvironmentName, Requirement, Source, TaskDefinitionField, File, Line, CurrentValue, DefaultValue, Reason, Evidence
```

Dockerfileやシェルスクリプトでインストール/セットアップしているソフトウェアの棚卸しは、既定で `docker-context-checker-software.csv` にUTF-8 BOM付きCSVとして出力します。ベースイメージ、Javaバージョンの推定情報、パッケージマネージャで導入しているOSパッケージ、ダウンロード/展開しているアーカイブ、WildFly/JBoss設定、取り込んでいるJDBCドライバJARやjboss-cliのdriver設定を一覧化します。

```bash
./docker-context-checker.sh -c /path/to/context --software-output software.csv
./docker-context-checker.sh -c /path/to/context --no-software-output
```

ソフトウェアCSV列:

```text
No, SoftwareName, Type, Version, SourceOrInstallMethod, Phase, File, Line, Evidence, Note
```

Java/JVMパラメータとWildFly/JBoss CLIサブシステム設定の監査結果は、既定で `docker-context-checker-config.csv` にUTF-8 BOM付きCSVとして出力します。Javaの `-Xmx`、`-XX:MaxRAMPercentage`、`-Dfile.encoding` などのJVMオプション、`JAVA_OPTS` / `JAVA_TOOL_OPTIONS` などの変数、CLIファイル内の `/subsystem=...:add(...)` や `:write-attribute(...)` の属性を一覧化し、設定項目の説明、実設定値、推奨設定、推奨との差分評価を出します。

```bash
./docker-context-checker.sh -c /path/to/context --config-output config.csv
./docker-context-checker.sh -c /path/to/context --no-config-output
```

設定監査CSV列:

```text
No, Domain, Component, SettingItem, Description, ConfiguredValue, RecommendedSetting, DistanceFromRecommendation, Assessment, Phase, File, Line, Evidence
```

Dockerを実際に起動して、ビルド後イメージ内で `ksh` と `java -version` が実行できるか確認したい場合は、既定では無効の実行プローブを明示的に有効化します。詳細は [RUNTIME_PROBE_USAGE.md](RUNTIME_PROBE_USAGE.md) を参照してください。

```bash
./docker-context-checker.sh -c /path/to/context --runtime-probe
./docker-context-checker.sh -c /path/to/context --runtime-probe --runtime-probe-build-option "--secret=id=maven_settings,src=/secure/settings.xml"
```

## 主なチェック

- マルチステージ `FROM ... AS ...` と `COPY --from=` の参照チェック
- `COPY` / `ADD` 元リソースの存在、`.dockerignore` 除外、未参照リソースの検出
- `RUN --mount=type=secret` のBuildKit build secrets構文、`id=`、`target=`/`env=`、`required=true` などの検出とチェック
- Dockerfile final stageでのkshセットアップ状況と、任意のDocker実行プローブによるksh/java実行確認
- ビルドコンテキスト内シンボリックリンクの破損やコンテキスト外参照
- `RUN ln -s` はビルドフェーズ、entrypoint や呼び出しシェル内の `ln -s` は実行フェーズとして表示
- entrypoint と呼び出し先シェルの変数チェック
  - 未使用変数
  - 空初期化
  - 初期化前利用
  - 初期値なしで外部から受け取る必要がある疑い
  - `${VAR:?message}` による必須外部変数
- ECSタスク定義から渡すべき、または渡せる可能性がある環境変数とSecret候補の一覧化
- `jboss-cli.sh --file=...` の CLI ファイル検出
- CLI ファイルの括弧・引用符の構文ヒューリスティック、JNDI 名や naming binding の設定値チェック
- final stage が UBI 9.6 の場合の runtime 整合性チェック
  - root 実行
  - UBI minimal での bash / dnf / yum / useradd 利用
  - entrypoint 実行時の package install、`systemctl`、`subscription-manager`

## 終了コード

デフォルトでは `ERROR` がある場合に終了コード `1` になります。

```bash
./docker-context-checker.sh --fail-on warn   # WARN 以上で 1
./docker-context-checker.sh --fail-on never  # 常に 0
```
