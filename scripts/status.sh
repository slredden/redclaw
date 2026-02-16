#!/bin/bash

# Set up PATH for openclaw commands
export PATH="${HOME}/.npm-global/bin:${PATH}"

echo "╔════════════════════════════════════════╗"
echo "║       ${BOT_NAME} Status Dashboard          ║"
echo "╚════════════════════════════════════════╝"
echo ""

# Gateway process status
GW_PID=$(pgrep -f "openclaw gateway" 2>/dev/null | head -1)
if [ -n "$GW_PID" ]; then
    UPTIME=$(ps -p "$GW_PID" -o etime= 2>/dev/null | tr -d ' ')
    echo "✓ Gateway: RUNNING (PID: $GW_PID, Uptime: $UPTIME)"
else
    echo "✗ Gateway: NOT RUNNING"
fi

# Health probe
echo ""
echo "Health:"
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:${GATEWAY_PORT}/ 2>/dev/null)
if [ "$http_code" = "200" ]; then
    echo "  ✓ HTTP probe: OK (port ${GATEWAY_PORT})"
else
    echo "  ✗ HTTP probe: FAILED (port ${GATEWAY_PORT})"
fi

# Watchdog status
if crontab -l 2>/dev/null | grep -q "watchdog.sh"; then
    WATCHDOG_LOG="/home/${BOT_USER}/${BOT_NAME_LOWER}-watchdog.log"
    echo "  ✓ Watchdog: active (cron every 5m)"
    if [ -f "$WATCHDOG_LOG" ]; then
        LAST_RESTART=$(tail -1 "$WATCHDOG_LOG" 2>/dev/null)
        if [ -n "$LAST_RESTART" ]; then
            echo "    Last log: $LAST_RESTART"
        fi
    fi
else
    echo "  ⚠ Watchdog: not installed"
fi

# Backup status
echo ""
echo "Backups:"
BACKUP_DIR="${HOME}/${BOT_NAME_LOWER}-backups"
if [ -d "$BACKUP_DIR" ]; then
    BACKUP_COUNT=$(find "$BACKUP_DIR" -type d -name "auto-*" 2>/dev/null | wc -l)
    if [ "${BACKUP_COUNT:-0}" -gt 0 ]; then
        LATEST=$(ls -td "$BACKUP_DIR"/auto-* 2>/dev/null | head -1 | xargs basename)
        echo "  Count: $BACKUP_COUNT"
        echo "  Latest: $LATEST"
    else
        echo "  ⚠ No automated backups found (directory exists but empty)"
    fi
else
    echo "  ⚠ Backup directory not created yet (~/${BOT_NAME_LOWER}-backups)"
fi

# Disk usage
echo ""
echo "Storage:"
OPENCLAW_DIR="${HOME}/.openclaw"
echo "  Openclaw: $(du -sh "$OPENCLAW_DIR" 2>/dev/null | cut -f1)"
echo "  Backups: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo 'N/A')"
echo "  Available: $(df -h "${HOME}" | tail -1 | awk '{print $4}')"

# Config integrity
echo ""
echo "Config:"
CONFIG_FILE="${OPENCLAW_DIR}/openclaw.json"
if [ -f "$CONFIG_FILE" ]; then
    PERMS=$(stat -c %a "$CONFIG_FILE" 2>/dev/null)
    if [ "$PERMS" = "600" ]; then
        echo "  ✓ Permissions: $PERMS (secure)"
    else
        echo "  ⚠ Permissions: $PERMS (should be 600)"
    fi

    TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        echo "  ✓ Token length: ${#TOKEN} chars"
    else
        echo "  ⚠ No gateway token found"
    fi
else
    echo "  ✗ Config file not found: $CONFIG_FILE"
fi

echo ""
echo "Last updated: $(date)"
