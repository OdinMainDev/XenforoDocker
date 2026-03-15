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
