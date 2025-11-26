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

# 引数チェック
# もしも存在しなければエラーとする
if [[ $# -eq 0 ]]; then
  echo "Error: This script requires a backup date argument (YYYY-MM-DD)."
  echo "Usage: $0 2025-10-29"
  exit 1
fi

# === docker composeのyamlファイル指定対応 ===
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
DC_BASE="docker compose -f ${COMPOSE_FILE}"
# baclup日付指定（指定がなければ当日）引数でも指定可能
BACKUP_DATE_ARG="${BACKUP_DATE_ARG:-$(date +%Y-%m-%d)}"
BACKUP_DATE="${1:-$BACKUP_DATE}"

SERVICE_NAME="${SERVICE_NAME:-misskey}"
S3CFG_FILE="${S3CFG_FILE:?not set}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
ENCRYPTION_KEY="${ENCRYPTION_KEY:-}"
TMP_BASE="/tmp"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEMP_DIR=$(mktemp -d "$TMP_BASE/backup-${SERVICE_NAME}-XXXXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

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

log "Get ${SERVICE_NAME} archive job"
log "Backup date: ${BACKUP_DATE}"

# 最新のSQLバックアップファイルを取得
TAERGET_DATE_SQL="s3:$(s3cmd ls s3://$SERVICE_NAME/$BACKUP_DATE/ |grep dump |head -n1 |cut -d ":" -f3)"
log "Target backup file: ${TAERGET_DATE_SQL}"
s3cmd -c $S3CFG_FILE get ${TAERGET_DATE_SQL} $TEMP_DIR/backup.dump.enc
openssl enc -d -aes-256-cbc -salt -pbkdf2 -in $TEMP_DIR/backup.dump.enc -out backup.dump -k $ENCRYPTION_KEY

# 最新のRedisバックアップファイルを取得
TAERGET_DATE_REDIS="s3:$(s3cmd ls s3://$SERVICE_NAME/$BACKUP_DATE/ |grep rdb |head -n1 |cut  -d ":" -f3)"
log "Target backup file: ${TAERGET_DATE_REDIS}"
s3cmd -c $S3CFG_FILE get ${TAERGET_DATE_REDIS} $TEMP_DIR/backup.rdb.enc
openssl enc -d -aes-256-cbc -salt -pbkdf2 -in $TEMP_DIR/backup.rdb.enc -out backup.rdb -k $ENCRYPTION_KEY

log "Complete download backup files"