#!/bin/bash
# ${BOT_NAME} Automated Backup Script

BACKUP_ROOT=$HOME/${BOT_NAME_LOWER}-backups
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=$BACKUP_ROOT/auto-$DATE
ARCHIVE_NAME="${BOT_NAME_LOWER}-backup-$DATE.tar.gz"
LOCAL_RETENTION_DAYS=7

# Load SFTP config if present
CONF_FILE=~/.config/${BOT_NAME_LOWER}-backup.conf
if [[ -f "$CONF_FILE" ]]; then
    source "$CONF_FILE"
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# --- Core: Openclaw state ---
echo "Backing up ~/.openclaw..."
cp -pr ~/.openclaw "$BACKUP_DIR/"

# Create sanitized version (no secrets) for documentation
if command -v jq &> /dev/null; then
    jq 'del(.gateway.auth.token)' \
        ~/.openclaw/openclaw.json > \
        "$BACKUP_DIR/openclaw-sanitized.json" 2>/dev/null
fi

# --- Config files ---
echo "Backing up config files..."
mkdir -p "$BACKUP_DIR/config"
# Google Workspace auth (gog)
if [[ -d ~/.config/gogcli ]]; then
    cp -pr ~/.config/gogcli "$BACKUP_DIR/config/"
fi
# Backup config itself
if [[ -f ~/.config/${BOT_NAME_LOWER}-backup.conf ]]; then
    cp -p ~/.config/${BOT_NAME_LOWER}-backup.conf "$BACKUP_DIR/config/"
fi

# --- SSH keys ---
if [[ -d ~/.ssh ]]; then
    echo "Backing up SSH keys..."
    mkdir -p "$BACKUP_DIR/ssh"
    cp -p ~/.ssh/id_* "$BACKUP_DIR/ssh/" 2>/dev/null
    cp -p ~/.ssh/config "$BACKUP_DIR/ssh/" 2>/dev/null
    cp -p ~/.ssh/authorized_keys "$BACKUP_DIR/ssh/" 2>/dev/null
fi

# --- Crontab ---
echo "Backing up crontab..."
crontab -l > "$BACKUP_DIR/crontab.txt" 2>/dev/null

# --- Documentation ---
if [[ -d ~/${BOT_NAME_LOWER}-docs ]]; then
    echo "Backing up documentation..."
    cp -pr ~/${BOT_NAME_LOWER}-docs "$BACKUP_DIR/docs"
fi

# --- Standalone scripts ---
echo "Backing up standalone scripts..."
mkdir -p "$BACKUP_DIR/scripts"
for script in ~/backup-${BOT_NAME_LOWER}.sh ~/${BOT_NAME_LOWER}-watchdog.sh ~/status.sh ~/verify-baseline.sh; do
    if [[ -f "$script" ]]; then
        cp -p "$script" "$BACKUP_DIR/scripts/"
    fi
done

# --- Compress ---
echo "Compressing backup..."
tar -czf "$BACKUP_ROOT/$ARCHIVE_NAME" -C "$BACKUP_ROOT" "auto-$DATE"
rm -rf "$BACKUP_DIR"

ARCHIVE_SIZE=$(du -sh "$BACKUP_ROOT/$ARCHIVE_NAME" | cut -f1)
echo "$(date): Backup compressed - $ARCHIVE_NAME ($ARCHIVE_SIZE)" | \
    tee -a "$BACKUP_ROOT/backup.log"

# SFTP offsite upload (only if SFTP_HOST is configured)
if [[ -n "$SFTP_HOST" ]]; then
    SFTP_PORT="${SFTP_PORT:-22}"
    SFTP_REMOTE_PATH="${SFTP_REMOTE_PATH:-/backups}"
    SFTP_RETENTION_DAYS="${SFTP_RETENTION_DAYS:-30}"

    echo "Uploading to sftp://$SFTP_HOST:$SFTP_PORT$SFTP_REMOTE_PATH/..."

    # Build curl command
    CURL_ARGS=(curl --insecure -S -s)
    if [[ -n "$SFTP_KEY" ]]; then
        CURL_ARGS+=(--key "$SFTP_KEY")
    fi
    if [[ -n "$SFTP_PASS" ]]; then
        CURL_ARGS+=(--user "$SFTP_USER:$SFTP_PASS")
    else
        CURL_ARGS+=(--user "$SFTP_USER:")
    fi
    CURL_ARGS+=(-T "$BACKUP_ROOT/$ARCHIVE_NAME")
    CURL_ARGS+=("sftp://$SFTP_HOST:$SFTP_PORT$SFTP_REMOTE_PATH/$ARCHIVE_NAME")

    if "${CURL_ARGS[@]}"; then
        echo "$(date): SFTP upload OK - $ARCHIVE_NAME" | tee -a "$BACKUP_ROOT/backup.log"
    else
        echo "$(date): SFTP upload FAILED - $ARCHIVE_NAME" | tee -a "$BACKUP_ROOT/backup.log"
    fi

    # Remote cleanup: remove backups older than SFTP_RETENTION_DAYS
    CUTOFF_DATE=$(date -d "-${SFTP_RETENTION_DAYS} days" +%Y%m%d)

    # Build sftp connection args
    SFTP_CONN_ARGS=(-oPort="$SFTP_PORT" -oBatchMode=yes -oStrictHostKeyChecking=no)
    if [[ -n "$SFTP_KEY" ]]; then
        SFTP_CONN_ARGS+=(-oIdentityFile="$SFTP_KEY")
    fi

    # List remote files and find ones to delete
    REMOTE_FILES=$(echo "ls $SFTP_REMOTE_PATH/${BOT_NAME_LOWER}-backup-*.tar.gz" | \
        sftp "${SFTP_CONN_ARGS[@]}" "$SFTP_USER@$SFTP_HOST" 2>/dev/null | \
        grep "${BOT_NAME_LOWER}-backup-" || true)

    if [[ -n "$REMOTE_FILES" ]]; then
        BATCH_FILE=$(mktemp)
        while IFS= read -r FILE; do
            BASENAME=$(basename "$FILE")
            # Extract date portion (YYYYMMDD) from filename
            FILE_DATE=$(echo "$BASENAME" | sed -n 's/${BOT_NAME_LOWER}-backup-\([0-9]\{8\}\)-.*/\1/p')
            if [[ -n "$FILE_DATE" && "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
                echo "rm $SFTP_REMOTE_PATH/$BASENAME" >> "$BATCH_FILE"
            fi
        done <<< "$REMOTE_FILES"

        if [[ -s "$BATCH_FILE" ]]; then
            DELETED=$(wc -l < "$BATCH_FILE")
            sftp "${SFTP_CONN_ARGS[@]}" -b "$BATCH_FILE" "$SFTP_USER@$SFTP_HOST" 2>/dev/null
            echo "$(date): SFTP cleanup - removed $DELETED old backup(s)" | tee -a "$BACKUP_ROOT/backup.log"
        fi
        rm -f "$BATCH_FILE"
    fi
else
    echo "SFTP not configured, skipping offsite upload."
fi

# Clean up old local backups
find "$BACKUP_ROOT" -maxdepth 1 -name "${BOT_NAME_LOWER}-backup-*.tar.gz" -mtime +$LOCAL_RETENTION_DAYS -delete 2>/dev/null
# Also clean up any legacy uncompressed backup dirs
find "$BACKUP_ROOT" -maxdepth 1 -type d -name "auto-*" -mtime +$LOCAL_RETENTION_DAYS -exec rm -rf {} + 2>/dev/null

# Show summary
echo ""
echo "Backup saved to: $BACKUP_ROOT/$ARCHIVE_NAME"
echo "Total backups: $(find $BACKUP_ROOT -maxdepth 1 -name "${BOT_NAME_LOWER}-backup-*.tar.gz" | wc -l)"
