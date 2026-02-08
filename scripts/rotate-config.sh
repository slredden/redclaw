#!/bin/bash
# Called before openclaw modifies openclaw.json
# Keeps last 10 backups with timestamps

CONFIG=~/.openclaw/openclaw.json
BACKUP_DIR=~/.openclaw/config-history

mkdir -p "$BACKUP_DIR"

# Copy current config with timestamp
if [ -f "$CONFIG" ]; then
    cp "$CONFIG" "$BACKUP_DIR/openclaw-$(date +%Y%m%d-%H%M%S).json"
fi

# Keep only last 10 versions
ls -t "$BACKUP_DIR"/openclaw-*.json | tail -n +11 | xargs rm -f 2>/dev/null

echo "Config backed up to $BACKUP_DIR"
