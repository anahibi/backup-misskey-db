# Backup Misskey DB(for Docker)

MisskeyのデータベースをS3互換のオブジェクトストレージへバックアップします。  
対象のデータベースは、PostgresqlとRedisです。  
バックアップ成否をDiscordへ通知することが可能です。  

## 要件

- Misskey、Postgresql、RedisがDockerコンテナで動作していること。
  - Dockerコンテナ名やボリューム名は書き換えてください。
  - [compose.ymlの例](https://github.com/anahibi/teleho-misc/blob/main/compose.yml)
- 次のソフトウェアが導入済みであること。
  - s3cmd

## 使い方

任意のディレクトリにgit cloneします。  

```
mkdir /opt/backup /opt/backup/tmp && cd /opt/backup/
git clone https://github.com/anahibi/backup-misskey-db.git .
```

.envファイルを作成します。

```
cp .env.example .env
```

実行します。  

```
./backup.sh
```

## cronの設定例

cronに設定することで、バックアップを自動化できます。  
以下は毎日3時に定期実行する例です。

```
0 3 * * * /opt/backup/backup.sh
```

## リストアの例

オブジェクトストレージから、リストアしたい日付のバックアップデータをダウンロードします。

```
./get_backup.sh 2025-10-29
```

リストアを実行します。

```
./restore.sh --force
```
