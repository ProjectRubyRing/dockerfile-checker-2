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

## 主なチェック

- マルチステージ `FROM ... AS ...` と `COPY --from=` の参照チェック
- `COPY` / `ADD` 元リソースの存在、`.dockerignore` 除外、未参照リソースの検出
- ビルドコンテキスト内シンボリックリンクの破損やコンテキスト外参照
- `RUN ln -s` はビルドフェーズ、entrypoint や呼び出しシェル内の `ln -s` は実行フェーズとして表示
- entrypoint と呼び出し先シェルの変数チェック
  - 未使用変数
  - 空初期化
  - 初期化前利用
  - 初期値なしで外部から受け取る必要がある疑い
  - `${VAR:?message}` による必須外部変数
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
