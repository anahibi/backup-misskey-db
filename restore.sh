#!/bin/bash
set -eo pipefail
[ "${DEBUG:-false}" = "true" ] && set -x

cd "$(dirname "$0")"

# === .env自動読み込み ===
if [ -f .env ]; then
  # exportのみ有効な行を読み込む
  set -a
  source .env
  set +a
fi

# 引数チェック: --force フラグが指定された場合は実行する。
if [[ "$1" != "--force" ]]; then
  echo "Error: This script must be run with the --force flag to proceed."
  echo "Usage: $0 -force"
  exit 1
fi

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
DC_BASE="docker compose -f ${COMPOSE_FILE}"

echo "stop misskey"
$DC_BASE down mi

echo "Start restore db"
$DC_BASE up ${POSTGRES_CONTAINER} -d

# バックアップファイルのリストア
$DC_BASE exec -T ${POSTGRES_CONTAINER} \
 pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists < backup.dump

echo "Start restore redis"

$DC_BASE down ${REDIS_CONTAINER}

docker run --rm \
  -v misskey_redis-data:/data \
  -v "$(pwd)":/backup \
  redis:8-alpine \
  sh -c "cp /backup/backup.rdb /data/dump.rdb && chown redis:redis /data/dump.rdb"

$DC_BASE up ${REDIS_CONTAINER} -d

$DC_BASE up mi -d