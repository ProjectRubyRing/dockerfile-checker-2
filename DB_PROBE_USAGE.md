# Aurora MySQL DB Probe Usage

`--db-probe` は、静的チェックで検出したDB接続情報を使って Aurora MySQL へ簡易接続クエリを実行する任意機能です。

既定では無効です。検証端末からAurora MySQLエンドポイントへ到達でき、`mysql` または `mariadb` クライアントが利用できる場合だけ有効化してください。

## 基本

```bash
./docker-context-checker.sh -c /path/to/context --db-probe
```

検出対象:

- Dockerfile の `ENV DB_HOST=...`、`ENV JDBC_URL=...` など
- entrypoint.sh や呼び出し先シェルの `DB_USER=...`、`export DB_PASSWORD=...` など
- JBoss CLIファイルの datasource 設定
  - `connection-url`
  - `user-name`
  - `password`
  - `driver-name`
  - `jndi-name`

JBoss CLI内の `${env.DB_HOST}` や `${DB_HOST}` は、チェック実行時の環境変数、Dockerfile `ENV`、シェル内の代入値から可能な範囲で解決します。

## Aurora MySQLとして扱うURL

接続検証の対象は MySQL互換URLです。

```text
jdbc:mysql://host:3306/database
jdbc:mariadb://host:3306/database
mysql://host:3306/database
```

ホスト名に `.cluster-...rds.amazonaws.com`、`.cluster-ro-...rds.amazonaws.com`、または `aurora` が含まれる場合は、Aurora MySQLらしい接続先としてCSVに記録します。

## 認証情報

パスワードは接続には利用しますが、CSVには値を出さず `configured(masked)` として出力します。

JBoss CLIが環境変数参照になっている場合は、実行前に値を設定します。

```bash
export DB_HOST='app.cluster-xxxxxxxx.ap-northeast-1.rds.amazonaws.com'
export DB_PORT='3306'
export DB_NAME='appdb'
export DB_USER='appuser'
export DB_PASSWORD='secret'

./docker-context-checker.sh -c /path/to/context --db-probe
```

## オプション

```bash
--db-check-output db-checks.csv
```

DB接続検証結果CSVの出力先を指定します。既定は `docker-context-checker-db-checks.csv` です。

```bash
--db-probe-query "SELECT 1"
```

接続後に実行するSQLを指定します。既定は `SELECT 1` です。

```bash
--db-probe-timeout 15
```

接続試行ごとのタイムアウト秒数を指定します。既定は `10` 秒です。

```bash
--db-probe-client /usr/bin/mysql
--db-probe-client-option "--ssl-mode=REQUIRED"
```

mysql/mariadbクライアントのパスや追加オプションを指定します。Aurora側でSSL必須の場合は、環境のクライアントに合うSSLオプションを追加してください。

## CSV列

```text
No, Scope, Source, File, Line, JdbcUrl, Host, Port, Database, User, PasswordStatus, AuroraMySQLAssessment, ProbeQuery, Result, Severity, Message, Suggestion
```

主な `Result`:

| Result | Meaning |
| --- | --- |
| `SUCCESS` | 簡易クエリに成功 |
| `FAILED` | mysql/mariadbクライアントで接続またはクエリに失敗 |
| `INCOMPLETE` | host/userなど必須情報が不足 |
| `CLIENT_MISSING` | mysql/mariadbクライアントが見つからない |
| `SKIPPED` | Aurora MySQL向けURLではないため接続検証をスキップ |
| `NOT_RUN` | 接続候補は検出したが `--db-probe` が無効 |
| `NO_CANDIDATE` | DB接続候補を検出できない |

## 注意

- この機能はローカル端末からDBへ接続します。ECSタスク内からの到達性とはネットワーク経路が異なる場合があります。
- Auroraがプライベートサブネットにある場合は、VPN、踏み台、SSMポートフォワードなどで到達経路を用意してください。
- Security Group、NACL、Route Table、DNS、SSL要件、DBユーザー権限の影響を受けます。
- 本番DBに対して実行する場合は、読み取りのみの軽量クエリを指定してください。
