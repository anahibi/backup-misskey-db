# Backup Misskey DB(Postgresql and Redis on Docker)

Misskeyのデータベースをバックアップし、結果をDiscordへ通知するシェルスクリプトです。  

## 必要なもの

事前にs3cmdをインストールし、設定ファイルを作成してください。

## 使い方

.envファイルを作成します。

```
cp .env.example .env
```

実行します。  

```
bash backup.sh
```

## cronの設定例

cronを用いて定期実行する例です。

```
0 3 * * * /opt/backup/backup.sh
```
