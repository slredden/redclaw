#!/bin/bash
# ${BOT_NAME} Automated Backup Script

BACKUP_ROOT=$HOME/${BOT_NAME_LOWER}-backups
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=$BACKUP_ROOT/auto-$DATE

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Backup entire .openclaw directory
echo "Backing up ~/.openclaw..."
cp -pr ~/.openclaw "$BACKUP_DIR/"

# Create sanitized version (no secrets) for documentation
if command -v jq &> /dev/null; then
    jq 'del(.gateway.auth.token)' \
        ~/.openclaw/openclaw.json > \
        "$BACKUP_DIR/openclaw-sanitized.json" 2>/dev/null
fi

# Keep only last 14 days of auto backups
find "$BACKUP_ROOT" -type d -name "auto-*" -mtime +14 -exec rm -rf {} + 2>/dev/null

# Log completion
echo "$(date): Backup completed - Size: $(du -sh $BACKUP_DIR | cut -f1)" | \
    tee -a "$BACKUP_ROOT/backup.log"

# Show summary
echo ""
echo "Backup saved to: $BACKUP_DIR"
echo "Total backups: $(find $BACKUP_ROOT -type d -name "auto-*" | wc -l)"
