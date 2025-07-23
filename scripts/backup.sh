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

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

create_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/xenforo_backup_${timestamp}.sql"

    
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
        
        # Compress backup
        log_message "Compressing backup..."
        gzip "${backup_file}"
        
        # Set proper permissions
        chmod 600 "${backup_file}.gz"
        
        log_message "Backup completed successfully: ${backup_file}.gz"
        
        # Clean up old backups
        log_message "Cleaning up old backups (older than ${RETENTION_MINUTES} minutes)..."
        find "${BACKUP_DIR}" -name "xenforo_backup_*.sql.gz" -mmin +${RETENTION_MINUTES} -delete 2>/dev/null || true
        
        # List recent backups
        local backup_count=$(ls -1 "${BACKUP_DIR}"/xenforo_backup_*.sql.gz 2>/dev/null | wc -l)
        log_message "Total backups: ${backup_count}"
        
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
    create_backup
else
    # Continuous mode (for automatic backups)
    log_message "Starting backup service with ${BACKUP_INTERVAL} second intervals"
    log_message "Retention: ${RETENTION_MINUTES} minutes"
    
    while true; do
        create_backup
        log_message "Waiting ${BACKUP_INTERVAL} seconds until next backup..."
        sleep "${BACKUP_INTERVAL}"
    done
fi