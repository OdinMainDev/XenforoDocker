#!/bin/bash

# XenForo database backup script with cron functionality
# Runs backup every 5 minutes when used in continuous mode

set -e

# Configuration
BACKUP_DIR="/mysql_backups"
MYSQL_HOST="${MYSQL_HOST:-mysql}"
MYSQL_DATABASE="${MYSQL_DATABASE:-xenforo}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_ROOT_PASSWORD}"
RETENTION_MINUTES="${BACKUP_RETENTION_MINUTES:-30}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-300}"
RUN_ONCE="${RUN_ONCE:-false}"
NGINX_LOG_DIR="${NGINX_LOG_DIR:-/nginx_logs}"
NGINX_LOG_MAX_SIZE_MB="${NGINX_LOG_MAX_SIZE_MB:-500}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_THREAD_ID="${TELEGRAM_THREAD_ID:-}"
TELEGRAM_MESSAGE_PREFIX="${TELEGRAM_MESSAGE_PREFIX:-XenForo backup}"
BACKUP_ARCHIVE_PASSWORD="${BACKUP_ARCHIVE_PASSWORD:-}"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        return 0
    fi

    log_message "curl not found; attempting to install..."

    if command -v apt-get >/dev/null 2>&1; then
        if DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null 2>&1; then
            return 0
        fi
    elif command -v microdnf >/dev/null 2>&1; then
        if microdnf install -y curl >/dev/null 2>&1; then
            return 0
        fi
    elif command -v dnf >/dev/null 2>&1; then
        if dnf install -y curl >/dev/null 2>&1; then
            return 0
        fi
    elif command -v yum >/dev/null 2>&1; then
        if yum install -y curl >/dev/null 2>&1; then
            return 0
        fi
    elif command -v apk >/dev/null 2>&1; then
        if apk add --no-cache curl >/dev/null 2>&1; then
            return 0
        fi
    fi

    log_message "ERROR: curl is required for Telegram uploads but is unavailable"
    return 1
}

ensure_zip() {
    if command -v zip >/dev/null 2>&1; then
        return 0
    fi

    log_message "zip not found; attempting to install..."

    if command -v apt-get >/dev/null 2>&1; then
        if DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zip >/dev/null 2>&1; then
            return 0
        fi
    elif command -v microdnf >/dev/null 2>&1; then
        if microdnf install -y zip >/dev/null 2>&1; then
            return 0
        fi
    elif command -v dnf >/dev/null 2>&1; then
        if dnf install -y zip >/dev/null 2>&1; then
            return 0
        fi
    elif command -v yum >/dev/null 2>&1; then
        if yum install -y zip >/dev/null 2>&1; then
            return 0
        fi
    elif command -v apk >/dev/null 2>&1; then
        if apk add --no-cache zip >/dev/null 2>&1; then
            return 0
        fi
    fi

    log_message "ERROR: zip is required to build password-protected archives but is unavailable"
    return 1
}

send_backup_to_telegram() {
    local backup_path="$1"
    local timestamp="$2"

    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        log_message "Telegram credentials not configured; skipping upload for ${backup_path}"
        return 2
    fi

    if [ ! -f "$backup_path" ]; then
        log_message "ERROR: Backup file not found for Telegram upload: ${backup_path}"
        return 1
    fi

    if ! ensure_curl; then
        return 1
    fi

    local caption="${TELEGRAM_MESSAGE_PREFIX} (${timestamp})"
    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument"
    local response exit_code

    log_message "Uploading backup to Telegram..."

    if [ -n "$TELEGRAM_THREAD_ID" ]; then
        response=$(curl -sS -X POST "$url" \
            -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "message_thread_id=${TELEGRAM_THREAD_ID}" \
            -F "caption=${caption}" \
            -F "document=@${backup_path}") || exit_code=$?
    else
        response=$(curl -sS -X POST "$url" \
            -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "caption=${caption}" \
            -F "document=@${backup_path}") || exit_code=$?
    fi

    exit_code=${exit_code:-0}
    if [ "$exit_code" -ne 0 ]; then
        log_message "ERROR: Failed to reach Telegram API (curl exit code ${exit_code})"
        return 1
    fi

    if echo "$response" | grep -q '"ok":true'; then
        log_message "Backup uploaded to Telegram successfully"
        return 0
    fi

    local description
    description=$(echo "$response" | grep -o '"description":"[^"]*"' | head -n1 2>/dev/null || true)
    description=$(echo "$description" | sed 's/"description":"\(.*\)"/\1/' | sed 's/\\"/"/g')
    if [ -n "$description" ]; then
        log_message "ERROR: Telegram API error: ${description}"
    else
        log_message "ERROR: Telegram API returned unexpected response"
    fi
    return 1
}

enforce_nginx_log_limit() {
    if [ ! -d "${NGINX_LOG_DIR}" ]; then
        return 0
    fi

    if ! [[ "$NGINX_LOG_MAX_SIZE_MB" =~ ^[0-9]+$ ]] || [ "$NGINX_LOG_MAX_SIZE_MB" -le 0 ]; then
        log_message "Invalid nginx log size limit (${NGINX_LOG_MAX_SIZE_MB}); skipping enforcement"
        return 0
    fi

    local max_bytes=$(( NGINX_LOG_MAX_SIZE_MB * 1024 * 1024 ))
    local total_size
    total_size=$(du -sb "${NGINX_LOG_DIR}" 2>/dev/null | awk '{print $1}')

    if [ -z "$total_size" ]; then
        return 0
    fi

    if [ "$total_size" -le "$max_bytes" ]; then
        return 0
    fi

    log_message "Trimming nginx logs in ${NGINX_LOG_DIR} (current size: ${total_size} bytes, limit: ${max_bytes} bytes)"

    while [ "$total_size" -gt "$max_bytes" ]; do
        local oldest_record oldest_file
        oldest_record=$(find "${NGINX_LOG_DIR}" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -n 1)
        oldest_file=$(echo "$oldest_record" | cut -d' ' -f2-)

        if [ -z "$oldest_file" ]; then
            log_message "Unable to identify oldest log file; aborting log trim"
            break
        fi

        if [[ "$oldest_file" =~ \.(gz|zip|bz2|xz)$ ]]; then
            rm -f "$oldest_file" 2>/dev/null || true
            log_message "Removed archived log file: ${oldest_file}"
        else
            : > "$oldest_file"
            log_message "Truncated log file: ${oldest_file}"
        fi

        total_size=$(du -sb "${NGINX_LOG_DIR}" 2>/dev/null | awk '{print $1}')
        if [ -z "$total_size" ]; then
            break
        fi
    done

    total_size=${total_size:-0}
    log_message "Nginx logs trimmed. Current size: ${total_size} bytes"
}

create_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/xenforo_backup_${timestamp}.sql"
    local archive_file="${BACKUP_DIR}/xenforo_backup_${timestamp}.zip"

    
    # Create backup directory if it doesn't exist
    mkdir -p "${BACKUP_DIR}"
    
    log_message "Creating database backup..."
    
    # Create database backup
    if mysqldump -h "${MYSQL_HOST}" -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
        --single-transaction \
        --routines \
        --triggers \
        --lock-tables=false \
        "${MYSQL_DATABASE}" > "${backup_file}" 2>/dev/null; then
        
        if [ -z "${BACKUP_ARCHIVE_PASSWORD}" ]; then
            log_message "ERROR: BACKUP_ARCHIVE_PASSWORD is not set; cannot create protected archive"
            rm -f "${backup_file}"
            return 1
        fi

        if ! ensure_zip; then
            rm -f "${backup_file}"
            return 1
        fi

        # Create password-protected archive
        log_message "Creating password-protected backup archive..."
        if ! zip -j -q -P "${BACKUP_ARCHIVE_PASSWORD}" "${archive_file}" "${backup_file}" 2>/dev/null; then
            log_message "ERROR: Failed to create ZIP archive"
            rm -f "${backup_file}" "${archive_file}"
            return 1
        fi

        rm -f "${backup_file}"

        # Set proper permissions
        chmod 600 "${archive_file}"
        
        log_message "Backup completed successfully: ${archive_file}"

        send_backup_to_telegram "${archive_file}" "${timestamp}"
        local telegram_status=$?

        if [ $telegram_status -eq 0 ]; then
            rm -f "${archive_file}"
            log_message "Local backup removed after successful Telegram upload"
        elif [ $telegram_status -eq 2 ]; then
            log_message "Telegram upload skipped; retaining local backup at ${archive_file}"
        else
            log_message "Telegram upload failed; retaining local backup at ${archive_file}"
        fi

        # Clean up old backups
        log_message "Cleaning up local backups older than ${RETENTION_MINUTES} minutes..."
        find "${BACKUP_DIR}" -name "xenforo_backup_*.zip" -mmin +${RETENTION_MINUTES} -delete 2>/dev/null || true
        
        # List retained backups
        local backup_count
        backup_count=$(find "${BACKUP_DIR}" -name "xenforo_backup_*.zip" 2>/dev/null | wc -l | awk '{print $1}')
        log_message "Local backups retained: ${backup_count}"
        
        return 0
    else
        log_message "ERROR: Backup failed!"
        return 1
    fi
}

# Check if running in single backup mode or continuous mode
if [ "${RUN_ONCE}" = "true" ]; then
    # Single backup mode (for manual backups)
    log_message "Running single backup..."
    enforce_nginx_log_limit
    create_backup
    enforce_nginx_log_limit
else
    # Continuous mode (for automatic backups)
    log_message "Starting backup service with ${BACKUP_INTERVAL} second intervals"
    log_message "Retention: ${RETENTION_MINUTES} minutes"
    
    while true; do
        enforce_nginx_log_limit
        create_backup
        enforce_nginx_log_limit
        log_message "Waiting ${BACKUP_INTERVAL} seconds until next backup..."
        sleep "${BACKUP_INTERVAL}"
    done
fi
