#!/bin/bash
set -eo pipefail
[ "${DEBUG:-false}" = "true" ] && set -x

# === .env自動読み込み ===
if [ -f .env ]; then
  # exportのみ有効な行を読み込む
  set -a
  source .env
  set +a
fi

# === docker composeのyamlファイル指定対応 ===
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
DC_BASE="docker compose -f ${COMPOSE_FILE}"

SERVICE_NAME="${SERVICE_NAME:-misskey}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-db}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis}"
POSTGRES_USER="${POSTGRES_USER:?not set}"
POSTGRES_DB="${POSTGRES_DB:?not set}"
REDIS_PASSWORD="${REDIS_PASSWORD:?not set}"
S3CFG_FILE="${S3CFG_FILE:?not set}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
ENCRYPTION_KEY="${ENCRYPTION_KEY:-}"
ENABLE_VACCUM="${ENABLE_VACCUM:-false}"
TMP_BASE="/tmp"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEMP_DIR=$(mktemp -d "$TMP_BASE/backup-${SERVICE_NAME}-XXXXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

BACKUP_SQL_FILE="$TEMP_DIR/${SERVICE_NAME}-${TIMESTAMP}.dump"
BACKUP_REDIS_FILE="$TEMP_DIR/${SERVICE_NAME}-${TIMESTAMP}.rdb"
S3_BASE_PATH="s3://$SERVICE_NAME/$(date +%Y-%m-%d)"

log() {
  echo "$(date +%Y-%m-%d_%H:%M:%S): $1"
}

send_discord_notification() {
  local message="$1"
  local color="$2"
  local webhook_url="$DISCORD_WEBHOOK_URL"
  if [ -n "$webhook_url" ]; then
    curl -H "Content-Type: application/json" -X POST -d "{
      \"embeds\": [{
        \"description\": \"$message\",
        \"color\": $color
      }]
    }" "$webhook_url"
  fi
}

error_exit() {
  log "Error: $1"
  send_discord_notification "Error: $1" 15158332
  exit 1
}

log "Start ${SERVICE_NAME} backup job"
log "Using compose file: $COMPOSE_FILE"

if [ "$ENABLE_VACCUM" = "true" ]; then
  log "Running VACUUM ANALYZE on PostgreSQL: $POSTGRES_DB"
  if ! $DC_BASE exec -T \
      "$POSTGRES_CONTAINER" \
      psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "VACUUM ANALYZE;"; then
    error_exit "Failed to run VACUM ANALYZE on PostgreSQL database ($POSTGRES_CONTAINER)"
  fi
fi

# === PostgreSQLバックアップ取得 ===
log "Backing up PostgreSQL: $POSTGRES_DB"
if ! $DC_BASE exec -T \
    "$POSTGRES_CONTAINER" \
    pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    > "$BACKUP_SQL_FILE"; then
  error_exit "Failed to dump PostgreSQL database ($POSTGRES_CONTAINER)"
fi

if [ -n "$ENCRYPTION_KEY" ]; then
  log "Encrypting PostgreSQL backup"
  if ! openssl enc -aes-256-cbc -salt -pbkdf2 \
    -in "$BACKUP_SQL_FILE" -out "${BACKUP_SQL_FILE}.enc" -k "$ENCRYPTION_KEY"; then
    error_exit "Failed to encrypt PostgreSQL backup"
  fi
  SQL_TO_UPLOAD="${BACKUP_SQL_FILE}.enc"
else
  SQL_TO_UPLOAD="$BACKUP_SQL_FILE"
fi

log "Uploading PostgreSQL backup to S3"
if ! s3cmd -c "$S3CFG_FILE" put "$SQL_TO_UPLOAD" "$S3_BASE_PATH/backup-${SERVICE_NAME}-${TIMESTAMP}.dump"; then
  error_exit "Failed to upload PostgreSQL backup to S3"
fi

# === Redis dump取得 ===
log "Backing up Redis..."
REDIS_DUMP_PATH="/data/dump.rdb"

# BGSAVE を実行
$DC_BASE exec -e REDISCLI_AUTH="$REDIS_PASSWORD" $REDIS_CONTAINER redis-cli BGSAVE

# BGSAVE 完了を待機（最大30秒）
echo "Waiting for Redis BGSAVE to finish..."

for i in {1..30}; do
    IN_PROGRESS=$($DC_BASE exec -e REDISCLI_AUTH="$REDIS_PASSWORD" $REDIS_CONTAINER redis-cli INFO persistence | grep rdb_bgsave_in_progress | cut -d':' -f2 | tr -d '\r')
    STATUS=$($DC_BASE exec -e REDISCLI_AUTH="$REDIS_PASSWORD" $REDIS_CONTAINER redis-cli INFO persistence | grep rdb_last_bgsave_status | cut -d':' -f2 | tr -d '\r')

    if [ "$IN_PROGRESS" = "0" ]; then
        if [ "$STATUS" = "ok" ]; then
            echo " -> Redis save completed."
            break
        else
            error_exit " -> ERROR: Redis backup failed (status=$STATUS)"
            exit 1
        fi
    fi

    echo -n "."
    sleep 2
done

if [ "$STATUS" != "ok" ]; then
    error_exit "ERROR: Redis BGSAVE did not finish in time."
    exit 1
fi

# 最新のdump.rdbをホストにコピー
docker cp "$($DC_BASE ps -q $REDIS_CONTAINER)":$REDIS_DUMP_PATH "$BACKUP_REDIS_FILE"

if [ -n "$ENCRYPTION_KEY" ]; then
  log "Encrypting Redis backup"
  if ! openssl enc -aes-256-cbc -salt -pbkdf2 \
    -in "$BACKUP_REDIS_FILE" -out "${BACKUP_REDIS_FILE}.enc" -k "$ENCRYPTION_KEY"; then
    error_exit "Failed to encrypt Redis backup"
  fi
  REDIS_TO_UPLOAD="${BACKUP_REDIS_FILE}.enc"
else
  REDIS_TO_UPLOAD="$BACKUP_REDIS_FILE"
fi

log "Uploading Redis backup to S3"
if ! s3cmd -c "$S3CFG_FILE" put "$REDIS_TO_UPLOAD" "$S3_BASE_PATH/backup-${SERVICE_NAME}-${TIMESTAMP}.rdb"; then
  error_exit "Failed to upload Redis backup to S3"
fi

log "Backup completed successfully"
if [ "${NOTIFY_ON_ERROR:-false}" = "false" ]; then
  send_discord_notification "Backup for $SERVICE_NAME completed successfully" 3066993
fi
