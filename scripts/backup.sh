#!/bin/bash
# XenForo (MySQL) Backup Script with Telegram upload
# Password-protected ZIP archives
# Large files automatically split for Telegram

set -e

# ==============================
# Database configuration
# ==============================

MYSQL_HOST="${MYSQL_HOST:-mysql}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_DATABASE="${MYSQL_DATABASE:-xenforo}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"

# ==============================
# Backup configuration
# ==============================

BACKUP_INTERVAL_MINUTES="${BACKUP_INTERVAL_MINUTES:-5}"
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-300}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_DIR="/mysql_backups"
BACKUP_ARCHIVE_PASSWORD="${BACKUP_ARCHIVE_PASSWORD:-}"

# Telegram max safe file size
TELEGRAM_SPLIT_SIZE="${TELEGRAM_SPLIT_SIZE:-49M}"

# ==============================
# Nginx log configuration
# ==============================

NGINX_LOG_DIR="${NGINX_LOG_DIR:-/nginx_logs}"
NGINX_LOG_MAX_SIZE_MB="${NGINX_LOG_MAX_SIZE_MB:-500}"

# ==============================
# Telegram configuration
# ==============================

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_MESSAGE_PREFIX="${TELEGRAM_MESSAGE_PREFIX:-XenForo Backup}"

# ==============================
# Logging
# ==============================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ==============================
# Dependency checks
# ==============================

ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        return 0
    fi

    log "curl not found; attempting to install..."

    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null 2>&1 && return 0
    elif command -v microdnf >/dev/null 2>&1; then
        microdnf install -y curl >/dev/null 2>&1 && return 0
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl >/dev/null 2>&1 && return 0
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl >/dev/null 2>&1 && return 0
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl >/dev/null 2>&1 && return 0
    fi

    log "ERROR: curl is required for Telegram uploads but is unavailable"
    return 1
}

ensure_zip() {
    if command -v zip >/dev/null 2>&1; then
        return 0
    fi

    log "zip not found; attempting to install..."

    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zip >/dev/null 2>&1 && return 0
    elif command -v microdnf >/dev/null 2>&1; then
        microdnf install -y zip >/dev/null 2>&1 && return 0
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y zip >/dev/null 2>&1 && return 0
    elif command -v yum >/dev/null 2>&1; then
        yum install -y zip >/dev/null 2>&1 && return 0
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache zip >/dev/null 2>&1 && return 0
    fi

    log "ERROR: zip is required to build password-protected archives but is unavailable"
    return 1
}

# ==============================
# Telegram message
# ==============================

send_telegram_message() {

    local message="$1"

    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        log "Telegram not configured"
        return
    fi

    if ! ensure_curl; then
        return 1
    fi

    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

    curl -s -X POST "$url" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${message}" \
        > /dev/null
}

# ==============================
# Telegram document
# ==============================

send_telegram_document() {

    local file_path="$1"
    local caption="$2"

    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument"

    local response

    response=$(curl -sS -X POST "$url" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "document=@${file_path}" \
        -F "caption=${caption}" \
        -F "parse_mode=HTML")

    if echo "$response" | grep -q '"ok":true'; then
        return 0
    fi

    local description
    description=$(echo "$response" | grep -o '"description":"[^"]*"' | head -n1 2>/dev/null || true)
    description=$(echo "$description" | sed 's/"description":"\(.*\)"/\1/' | sed 's/\\"/"/g')
    if [ -n "$description" ]; then
        log "ERROR: Telegram API error: ${description}"
    else
        log "ERROR: Telegram API returned unexpected response"
    fi
    return 1
}

# ==============================
# Send large files (split)
# ==============================

send_large_file() {

    local file="$1"
    local caption="$2"

    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        log "Telegram not configured; skipping upload"
        return 2
    fi

    if [ ! -f "$file" ]; then
        log "ERROR: File not found for upload: ${file}"
        return 1
    fi

    if ! ensure_curl; then
        return 1
    fi

    local filesize
    filesize=$(stat -c%s "$file")

    if [ "$filesize" -lt 50000000 ]; then
        log "Uploading backup to Telegram..."
        send_telegram_document "$file" "$caption"
        return $?
    fi

    log "File larger than Telegram limit. Splitting..."

    local base="${file}.part-"

    split -b "$TELEGRAM_SPLIT_SIZE" -d "$file" "$base"

    local part_num=0
    local total_parts
    total_parts=$(ls -1 ${base}* 2>/dev/null | wc -l)

    for part in ${base}*; do

        part_num=$((part_num + 1))
        log "Uploading part ${part_num}/${total_parts}: $(basename "$part")"

        if ! send_telegram_document "$part" "${caption} (part ${part_num}/${total_parts})"; then
            log "Upload failed at part ${part_num}"
            rm -f ${base}*
            return 1
        fi

        sleep 1

    done

    rm -f ${base}*
    log "All ${total_parts} parts uploaded successfully"

    return 0
}

# ==============================
# Wait for database
# ==============================

wait_for_db() {

    log "Waiting for MySQL..."

    local attempts=30

    for ((i=1;i<=attempts;i++)); do

        if mysqladmin ping -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent 2>/dev/null; then
            log "MySQL ready"
            return 0
        fi

        log "Attempt $i/$attempts"
        sleep 2

    done

    log "MySQL unavailable"
    return 1
}

# ==============================
# Nginx log enforcement
# ==============================

enforce_nginx_log_limit() {

    if [ ! -d "${NGINX_LOG_DIR}" ]; then
        return 0
    fi

    if ! [[ "$NGINX_LOG_MAX_SIZE_MB" =~ ^[0-9]+$ ]] || [ "$NGINX_LOG_MAX_SIZE_MB" -le 0 ]; then
        log "Invalid nginx log size limit (${NGINX_LOG_MAX_SIZE_MB}); skipping"
        return 0
    fi

    local max_bytes=$(( NGINX_LOG_MAX_SIZE_MB * 1024 * 1024 ))
    local total_size
    total_size=$(du -sb "${NGINX_LOG_DIR}" 2>/dev/null | awk '{print $1}')

    if [ -z "$total_size" ] || [ "$total_size" -le "$max_bytes" ]; then
        return 0
    fi

    log "Trimming nginx logs (current: ${total_size} bytes, limit: ${max_bytes} bytes)"

    while [ "$total_size" -gt "$max_bytes" ]; do
        local oldest_file
        oldest_file=$(find "${NGINX_LOG_DIR}" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -n 1 | cut -d' ' -f2-)

        if [ -z "$oldest_file" ]; then
            break
        fi

        if [[ "$oldest_file" =~ \.(gz|zip|bz2|xz)$ ]]; then
            rm -f "$oldest_file" 2>/dev/null || true
            log "Removed archived log: ${oldest_file}"
        else
            : > "$oldest_file"
            log "Truncated log: ${oldest_file}"
        fi

        total_size=$(du -sb "${NGINX_LOG_DIR}" 2>/dev/null | awk '{print $1}')
        if [ -z "$total_size" ]; then
            break
        fi
    done

    log "Nginx logs trimmed. Current size: ${total_size:-0} bytes"
}

# ==============================
# Backup creation
# ==============================

create_backup() {

    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

    local hostname
    hostname=$(hostname)

    local backup_file="${BACKUP_DIR}/xenforo_backup_${timestamp}.sql"
    local archive_file="${BACKUP_DIR}/xenforo_backup_${timestamp}.zip"

    log "Starting backup"

    local dump_cmd="mysqldump \
        -h '${MYSQL_HOST}' \
        -P '${MYSQL_PORT}' \
        -u '${MYSQL_USER}' \
        -p'${MYSQL_PASSWORD}' \
        --single-transaction \
        --routines \
        --triggers \
        --lock-tables=false \
        '${MYSQL_DATABASE}'"

    if timeout "$BACKUP_TIMEOUT" bash -c "$dump_cmd" > "${backup_file}" 2>/dev/null; then

        if [ -z "${BACKUP_ARCHIVE_PASSWORD}" ]; then
            log "ERROR: BACKUP_ARCHIVE_PASSWORD is not set; cannot create protected archive"
            rm -f "${backup_file}"
            return 1
        fi

        if ! ensure_zip; then
            rm -f "${backup_file}"
            return 1
        fi

        log "Creating password-protected archive..."
        if ! zip -j -q -P "${BACKUP_ARCHIVE_PASSWORD}" "${archive_file}" "${backup_file}" 2>/dev/null; then
            log "ERROR: Failed to create ZIP archive"
            rm -f "${backup_file}" "${archive_file}"
            return 1
        fi

        rm -f "${backup_file}"
        chmod 600 "${archive_file}"

        local size
        size=$(du -h "${archive_file}" | cut -f1)

        log "Backup created: ${archive_file} ($size)"

        local caption="📦 <b>${TELEGRAM_MESSAGE_PREFIX}</b>
<b>Database:</b> ${MYSQL_DATABASE}
<b>Host:</b> ${hostname}
<b>Time:</b> ${timestamp}
<b>Size:</b> ${size}"

        local upload_status
        send_large_file "${archive_file}" "$caption"
        upload_status=$?

        if [ $upload_status -eq 0 ]; then
            rm -f "${archive_file}"
            log "Backup uploaded and local file removed"
        elif [ $upload_status -eq 2 ]; then
            log "Telegram skipped; keeping local backup"
        else
            log "Upload failed; keeping local backup"
        fi

        return 0
    else

        log "Backup failed"

        send_telegram_message "🔴 <b>Backup failed</b>
Database: ${MYSQL_DATABASE}
Host: ${hostname}
Time: ${timestamp}"

        return 1
    fi
}

# ==============================
# Cleanup
# ==============================

cleanup_old_backups() {

    if [ "$BACKUP_RETENTION_DAYS" -gt 0 ]; then

        log "Cleaning backups older than $BACKUP_RETENTION_DAYS days"

        find "$BACKUP_DIR" -name "xenforo_backup_*.zip" -type f -mtime +"$BACKUP_RETENTION_DAYS" -delete 2>/dev/null || true

    fi
}

# ==============================
# Main
# ==============================

main() {

    log "XenForo Backup Service started"

    mkdir -p "$BACKUP_DIR"

    if ! wait_for_db; then
        exit 1
    fi

    enforce_nginx_log_limit
    create_backup || true
    cleanup_old_backups

    local interval=$((BACKUP_INTERVAL_MINUTES * 60))

    while true; do

        log "Next backup in $BACKUP_INTERVAL_MINUTES minutes"

        sleep "$interval"

        enforce_nginx_log_limit
        create_backup || true
        cleanup_old_backups

    done
}

# ==============================
# Single run
# ==============================

if [ "$1" = "--once" ]; then
    enforce_nginx_log_limit
    wait_for_db && create_backup
    exit $?
fi

main
